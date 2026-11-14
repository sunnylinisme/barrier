// SPDX-License-Identifier: GPL-2.0-or-later
#include "AsyncFileClipboardTransfer.h"
#include "ProtocolUtil.h"
#include "io/IStream.h"
#include "base/IEventQueue.h"
#include "base/TMethodEventJob.h"
#include "base/Log.h"
#include "common/DataDirectories.h"
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace barrier {
namespace {
constexpr size_t packetLimit = 65560, queueLimit = 16;
Event::Type readyType = Event::kUnknown;
// A disconnected filesystem operation may remain in the kernel. Bound such workers.
std::atomic<unsigned>& workerCount() { static auto count = new std::atomic<unsigned>(0); return *count; }
uint32_t packetId(const std::string& packet) {
    if (packet.size() < 8) return 0;
    auto p = reinterpret_cast<const unsigned char*>(packet.data() + 4);
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
struct Result { std::string packet, handle, error; ClipboardID clipboard = 0; uint32_t sequence = 0, transfer = 0, finishedSend = 0; };
class MemoryStream : public IStream {
public:
    std::string input; std::deque<Result> output; std::function<void()> beforeOutput; uint32_t currentId = 0;
    UInt32 read(void* bytes, UInt32 count) override {
        count = std::min<UInt32>(count, input.size()); if (bytes) memcpy(bytes, input.data(), count); input.erase(0, count); return count;
    }
    void write(const void* bytes, UInt32 count) override {
        if (count > packetLimit || output.size() >= queueLimit) throw std::runtime_error("File clipboard queue exceeded");
        if (beforeOutput) beforeOutput();
        Result result; result.packet.assign(static_cast<const char*>(bytes), count); output.push_back(std::move(result));
    }
    UInt32 getSize() const override { return static_cast<UInt32>(input.size()); }
    bool isReady() const override { return !input.empty(); }
    void* getEventTarget() const override { return nullptr; }
    void close() override {} void flush() override {} void shutdownInput() override {} void shutdownOutput() override {}
};
}
struct AsyncFileClipboardTransfer::State {
    struct Job { enum Kind { Start, Receive, Cancel } kind; uint64_t generation; std::string data; ClipboardID clipboard = 0; uint32_t sequence = 0; };
    std::mutex mutex; std::condition_variable wake;
    std::deque<Job> jobs; std::deque<Result> results;
    uint64_t generation = 0;
    bool stopping = false, notified = false, available = true;
    IEventQueue* events;
    explicit State(IEventQueue* queue) : events(queue) {}
    static void run(std::shared_ptr<State> state, fs::path cache, std::function<void()> beforeOutput) {
        struct CountGuard { ~CountGuard() { --workerCount(); } } countGuard;
        MemoryStream memory; memory.beforeOutput = std::move(beforeOutput);
        FileClipboardTransfer transfer(&memory, [&](ClipboardID id, uint32_t sequence, const std::string& handle) {
            Result result; result.clipboard = id; result.sequence = sequence; result.handle = handle; result.transfer = memory.currentId; memory.output.push_back(std::move(result));
        }, cache);
        while (true) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(state->mutex);
                state->wake.wait(lock, [&] { return state->stopping || !state->jobs.empty(); });
                if (state->stopping) return;
                job = std::move(state->jobs.front()); state->jobs.pop_front();
            }
            memory.output.clear();
            try {
                // Cancelled queued work must not touch disk. In-flight results are checked below.
                { std::lock_guard<std::mutex> lock(state->mutex); if (state->stopping) return; if (job.generation != state->generation) continue; }
                if (job.kind == Job::Start) transfer.start(job.data, job.clipboard, job.sequence);
                else if (job.kind == Job::Cancel) transfer.cancel();
                else {
                    memory.currentId = packetId(job.data);
                    memory.input = job.data.substr(4);
                    if (!transfer.receive(reinterpret_cast<const unsigned char*>(job.data.data())) || !memory.input.empty())
                        throw std::runtime_error("Invalid file clipboard packet");
                    if ((job.data.compare(0, 4, "FCAK") == 0 || job.data.compare(0, 4, "FCNO") == 0) && !transfer.sending()) {
                        Result result; result.finishedSend = memory.currentId; memory.output.push_back(std::move(result));
                    }
                }
            } catch (const std::exception& error) {
                Result result; result.error = error.what(); memory.output.push_back(std::move(result));
            }
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->stopping) return;
            if (job.generation != state->generation) continue;
            if (state->results.size() + memory.output.size() > queueLimit) { state->available = false; state->jobs.clear(); memory.output.clear(); Result result; result.error = "File clipboard queue exceeded"; memory.output.push_back(std::move(result)); state->results.clear(); }
            for (auto& result : memory.output) state->results.push_back(std::move(result));
            if (!state->results.empty() && state->events && !state->notified) {
                state->notified = true;
                state->events->addEvent(Event(readyType, state.get()));
            }
        }
    }
};
AsyncFileClipboardTransfer::AsyncFileClipboardTransfer(IStream* stream, FileClipboardTransfer::Completed completed,
    IEventQueue* events, const fs::path& cache, std::function<void()> beforeOutput) :
    state_(new State(events)), stream_(stream), completed_(std::move(completed)), events_(events) {
    if (events_) {
        events_->registerTypeOnce(readyType, "fileClipboardDiskReady");
        events_->adoptHandler(readyType, state_.get(), new TMethodEventJob<AsyncFileClipboardTransfer>(this, &AsyncFileClipboardTransfer::ready));
    }
    if (workerCount().fetch_add(1) >= 8) { --workerCount(); state_->available = false; return; }
    try { std::thread(State::run, state_, cache.empty() ? DataDirectories::profile() / "FileClipboardCache" : cache, std::move(beforeOutput)).detach(); }
    catch (...) { --workerCount(); state_->available = false; }
}
AsyncFileClipboardTransfer::~AsyncFileClipboardTransfer() {
    { std::lock_guard<std::mutex> lock(state_->mutex); state_->stopping = true; state_->events = nullptr; state_->jobs.clear(); state_->results.clear(); }
    state_->wake.notify_one();
    if (events_) events_->removeHandler(readyType, state_.get());
    // No join: filesystem providers can block indefinitely. The worker owns no UI/network pointers.
}
void AsyncFileClipboardTransfer::finishShutdown(int exitCode) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
    while (workerCount().load() != 0) {
        // A cloud/network filesystem may never return. Do not destroy globals
        // that an outstanding worker could still use after its I/O resumes.
        if (std::chrono::steady_clock::now() >= deadline) std::_Exit(exitCode);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
void AsyncFileClipboardTransfer::cancel() {
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        ++state_->generation; state_->jobs.clear(); state_->results.clear();
        if (state_->available) state_->jobs.push_back({State::Job::Cancel, state_->generation, {}});
    }
    state_->wake.notify_one();
    if (outgoing_) ProtocolUtil::writef(stream_, "FCAB%4i", outgoing_);
    if (incoming_) { std::string reason = "Clipboard changed or transfer cancelled"; ProtocolUtil::writef(stream_, "FCNO%4i%s", incoming_, &reason); }
    outgoing_ = incoming_ = 0;
}
void AsyncFileClipboardTransfer::start(const std::string& handle, ClipboardID clipboard, uint32_t sequence) {
    cancel();
    { std::lock_guard<std::mutex> lock(state_->mutex);
      if (!state_->available) throw std::runtime_error("File access is unavailable; restart Barrier Share after checking the source drive");
      state_->jobs.push_back({State::Job::Start, state_->generation, handle, clipboard, sequence}); }
    state_->wake.notify_one();
}
bool AsyncFileClipboardTransfer::receive(const unsigned char* code) {
    // Callers supply a PacketStreamFilter: getSize is the remainder of THIS frame.
    const auto size = stream_->getSize();
    if (size < 4 || size > packetLimit - 4) return false;
    std::string packet(reinterpret_cast<const char*>(code), 4); packet.resize(size + 4);
    if (stream_->read(&packet[4], size) != size) return false;
    const auto command = packet.substr(0, 4);
    if (command != "FCBG" && command != "FCEN" && command != "FCHK" && command != "FCFE" && command != "FCDN" && command != "FCAK" && command != "FCAB" && command != "FCNO") return false;
    if (command == "FCBG") incoming_ = packetId(packet);
    if (command == "FCAB" && incoming_ == packetId(packet)) incoming_ = 0;
    if (command == "FCNO" && outgoing_ == packetId(packet)) outgoing_ = 0;
    bool starting = false; ClipboardID clipboard = 0; uint32_t sequence = 0;
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (!state_->available) {
            if (command == "FCBG") { std::string reason = "File access is unavailable; restart Barrier Share"; ProtocolUtil::writef(stream_, "FCNO%4i%s", incoming_, &reason); incoming_ = 0; }
            return true;
        }
        if (state_->jobs.size() >= queueLimit) return false;
        if (command == "FCBG" && packet.size() >= 13) {
            auto p = reinterpret_cast<const unsigned char*>(packet.data());
            starting = true; clipboard = p[8];
            sequence = (uint32_t(p[9]) << 24) | (uint32_t(p[10]) << 16) | (uint32_t(p[11]) << 8) | p[12];
        }
        state_->jobs.push_back({State::Job::Receive, state_->generation, std::move(packet)}); state_->wake.notify_one();
    }
    if (starting && started_) started_(clipboard, sequence);
    return true;
}
void AsyncFileClipboardTransfer::ready(const Event&, void*) { poll(); }
void AsyncFileClipboardTransfer::poll() {
    auto state = state_; auto completed = completed_; auto stream = stream_;
    std::deque<Result> results; uint64_t generation; uint32_t published = 0;
    { std::lock_guard<std::mutex> lock(state->mutex); results.swap(state->results); state->notified = false; generation = state->generation; }
    for (const auto& result : results) {
        // Publishing a clipboard may reentrantly cancel/start another transfer.
        { std::lock_guard<std::mutex> lock(state->mutex); if (state->stopping || generation != state->generation) return; }
        try {
            if (!result.error.empty()) throw std::runtime_error(result.error);
            if (result.finishedSend && outgoing_ == result.finishedSend) outgoing_ = 0;
            if (!result.packet.empty()) {
                if (result.packet.compare(0, 4, "FCAK") == 0 && packetId(result.packet) != incoming_ && packetId(result.packet) != published) continue;
                if (result.packet.compare(0, 4, "FCBG") == 0) outgoing_ = packetId(result.packet);
                if (result.packet.compare(0, 4, "FCAB") == 0 && outgoing_ == packetId(result.packet)) outgoing_ = 0;
                if (result.packet.compare(0, 4, "FCNO") == 0 && incoming_ == packetId(result.packet)) incoming_ = 0;
                stream->write(result.packet.data(), static_cast<UInt32>(result.packet.size()));
            }
            if (!result.handle.empty() && incoming_ == result.transfer) {
                completed(result.clipboard, result.sequence, result.handle);
                { std::lock_guard<std::mutex> lock(state->mutex); if (state->stopping || generation != state->generation) return; }
                published = result.transfer;
                if (incoming_ == result.transfer) incoming_ = 0;
            }
        } catch (const std::exception& error) {
            LOG((CLOG_WARN "file clipboard: %s", error.what()));
            { std::lock_guard<std::mutex> lock(state->mutex); if (state->stopping) return; }
            try { cancel(); } catch (const std::exception&) { }
            return;
        }
    }
}
}
