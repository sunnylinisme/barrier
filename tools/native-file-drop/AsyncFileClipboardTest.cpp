// SPDX-License-Identifier: GPL-2.0-or-later
#include "barrier/AsyncFileClipboardTransfer.h"
#include "barrier/ProtocolUtil.h"
#include "io/IStream.h"
#include "arch/Arch.h"
#include "base/Log.h"
#include "base/EventQueue.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
#if SYSAPI_WIN32
#include "arch/win32/ArchMiscWindows.h"
#endif
using namespace barrier;
using Clock = std::chrono::steady_clock;
static void check(bool value, const char* why) { if (!value) throw std::runtime_error(why); }
class Pipe : public IStream {
    const std::thread::id owner = std::this_thread::get_id();
    void mainOnly() const { if (!attached) accessedAfterDetach = true; check(attached, "Network accessed after connection destruction"); check(std::this_thread::get_id() == owner, "Network touched by disk worker"); }
public:
    bool attached = true; mutable bool accessedAfterDetach = false;
    std::deque<std::string> packets; std::string input;
    void write(const void* bytes, UInt32 count) override {
        mainOnly(); check(count <= 65560, "Unbounded output packet"); packets.emplace_back(static_cast<const char*>(bytes), count);
    }
    UInt32 read(void* bytes, UInt32 count) override {
        mainOnly(); count = std::min<UInt32>(count, input.size()); if (bytes) memcpy(bytes, input.data(), count); input.erase(0, count); return count;
    }
    UInt32 getSize() const override { mainOnly(); return static_cast<UInt32>(input.size()); }
    bool isReady() const override { mainOnly(); return !input.empty(); }
    void* getEventTarget() const override { return nullptr; }
    void close() override {} void flush() override {} void shutdownInput() override {} void shutdownOutput() override {}
};
template<class Transfer> static void pass(Pipe& outgoing, Pipe& incoming, Transfer& target) {
    if (outgoing.packets.empty()) return;
    auto packet = std::move(outgoing.packets.front()); outgoing.packets.pop_front();
    check(packet.size() >= 8, "Invalid frame"); incoming.input = packet.substr(4);
    check(target.receive(reinterpret_cast<const unsigned char*>(packet.data())), "Async parser rejected valid frame");
    check(incoming.input.empty(), "Async parser left frame bytes unread");
}
template<class Predicate> static void waitFor(Predicate predicate, const char* why) {
    auto deadline = Clock::now() + std::chrono::seconds(10);
    while (!predicate()) { check(Clock::now() < deadline, why); std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
}
static bool sameBytes(const fs::path& a, const fs::path& b) {
    if (fs::file_size(a) != fs::file_size(b)) return false;
    std::ifstream x, y; open_utf8_path(x, a, std::ios::binary); open_utf8_path(y, b, std::ios::binary);
    char first[65536], second[65536];
    while (x) { x.read(first, sizeof(first)); y.read(second, sizeof(second)); if (x.gcount() != y.gcount() || memcmp(first, second, x.gcount())) return false; }
    return x.eof() && y.eof();
}
struct Gate {
    std::mutex mutex; std::condition_variable wake; bool armed = false, blocked = false, released = false;
    std::atomic<unsigned> calls{0};
    void touch() {
        ++calls;
        std::unique_lock<std::mutex> lock(mutex);
        if (!armed) return;
        armed = false; blocked = true; wake.notify_all(); wake.wait(lock, [&] { return released; });
    }
    void arm() { std::lock_guard<std::mutex> lock(mutex); armed = true; blocked = released = false; }
    void waitBlocked() { std::unique_lock<std::mutex> lock(mutex); check(wake.wait_for(lock, std::chrono::seconds(5), [&] { return blocked; }), "Disk worker did not reach blocked operation"); }
    void release() { std::lock_guard<std::mutex> lock(mutex); released = true; wake.notify_all(); }
};
static void timely(Clock::time_point start, const char* why) { check(Clock::now() - start < std::chrono::milliseconds(250), why); }
int main(int argc, char** argv) {
#if SYSAPI_WIN32
    ArchMiscWindows::setInstanceWin32(GetModuleHandle(nullptr));
#endif
    Arch arch; arch.init(); Log log; log.setFilter(kWARNING); std::cout << std::unitbuf;
    EventQueue events; events.addEvent(Event(Event::kQuit)); events.loop();
    auto dispatch = [&] { Event event; while (events.getEvent(event, 0.0)) { events.dispatchEvent(event); Event::deleteData(event); } };
    auto root = fs::temp_directory_path() / ("async-clipboard-" + std::to_string(Clock::now().time_since_epoch().count()));
    try {
        auto source = root / "source"; fs::create_directories(source / "folder" / "empty");
        auto large = source / "large.bin", small = source / "folder" / "small.txt";
        { std::ofstream out; open_utf8_path(out, large, std::ios::binary); std::string bytes(65536, '\0'); for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = char(i * 37); for (int i = 0; i < 32; ++i) out.write(bytes.data(), bytes.size()); }
        { std::ofstream out; open_utf8_path(out, small, std::ios::binary); out << "bidirectional async clipboard"; }
        if (argc == 2 && std::string(argv[1]) == "--blocked-shutdown") {
            Pipe pipe; auto gate = std::make_shared<Gate>(); gate->arm();
            auto transfer = std::make_unique<AsyncFileClipboardTransfer>(&pipe, [](ClipboardID, uint32_t, const std::string&) {}, &events,
                root / "shutdown-cache", [gate] { gate->touch(); });
            transfer->start(registerClipboardFiles({small}), 0, 1); gate->waitBlocked(); transfer.reset();
            fs::remove_all(root);
            std::cout << "PASS: entering bounded process shutdown with a blocked detached disk worker\n";
            AsyncFileClipboardTransfer::finishShutdown(0);
            throw std::runtime_error("Blocked shutdown returned with a live disk worker");
        }
        const auto mainThread = std::this_thread::get_id();
        Pipe a, b; std::string atA, atB; uint32_t sequenceA = 0, sequenceB = 0;
        auto gateA = std::make_shared<Gate>(), gateB = std::make_shared<Gate>();
        auto makeHook = [mainThread](std::shared_ptr<Gate> gate) { return [mainThread, gate] { check(std::this_thread::get_id() != mainThread, "Disk work ran on input thread"); gate->touch(); }; };
        std::unique_ptr<AsyncFileClipboardTransfer> first, second;
        auto buildPeers = [&] {
        first = std::make_unique<AsyncFileClipboardTransfer>(&a, [&](ClipboardID id, uint32_t sequence, const std::string& handle) { check(std::this_thread::get_id() == mainThread && id == 0, "Completion left input thread"); atA = handle; sequenceA = sequence; }, &events, root / "cache-a", makeHook(gateA));
        second = std::make_unique<AsyncFileClipboardTransfer>(&b, [&](ClipboardID id, uint32_t sequence, const std::string& handle) { check(std::this_thread::get_id() == mainThread && id == 0, "Completion left input thread"); atB = handle; sequenceB = sequence; }, &events, root / "cache-b", makeHook(gateB));
        };
        buildPeers();
        std::string cancelledId;
        auto pump = [&] {
            dispatch();
            if (!cancelledId.empty()) for (const auto& packet : a.packets) {
                const auto kind = packet.substr(0, 4);
                check(packet.substr(4, 4) != cancelledId || (kind != "FCEN" && kind != "FCHK" && kind != "FCFE" && kind != "FCDN"),
                      "Mid-operation result escaped after cancellation");
            }
            pass(a, b, *second); pass(b, a, *first);
        };
        auto completedCancelIsSilent = [&] {
            // The receiver callback precedes the final ACK. Wait for the sender to
            // process that ACK and publish its finished-send result to the event queue.
            waitFor([&] { Event event; if (!events.getEvent(event, 0.0)) return false; events.dispatchEvent(event); Event::deleteData(event); return true; },
                    "Sender did not report final acknowledgement completion");
            dispatch(); check(a.packets.empty() && b.packets.empty(), "Completed transfer left protocol traffic");
            first->cancel(); second->cancel();
            check(a.packets.empty() && b.packets.empty(), "Cancelling a completed transfer sent stale abort/rejection");
        };
        first->start(registerClipboardFiles({large, source / "folder"}), 0, 42);
        waitFor([&] { pump(); return !atB.empty(); }, "Async forward transfer did not finish");
        auto received = clipboardFiles(atB);
        check(sequenceB == 42 && received->roots.size() == 2 && sameBytes(large, received->roots[0]), "Forward bytes or sequence differ");
        check(sameBytes(small, received->roots[1] / "small.txt") && fs::is_directory(received->roots[1] / "empty"), "Folder structure differs");
        completedCancelIsSilent();
        second->start(registerClipboardFiles({small}), 0, 43);
        waitFor([&] { pump(); return !atA.empty(); }, "Async reverse transfer did not finish");
        check(sequenceA == 43 && sameBytes(small, clipboardFiles(atA)->roots[0]), "Reverse bytes differ");
        completedCancelIsSilent();
        check(gateA->calls > 30 && gateB->calls > 30, "Chunk transfer bypassed worker");
        std::cout << "PASS: real async file/folder bytes both directions via EventQueue notifications; input-thread-only network and completion callbacks\n";

        // Use a fresh connection for the deterministic stall, with no previous ACKs in flight.
        std::weak_ptr<Gate> oldA = gateA, oldB = gateB;
        first.reset(); second.reset(); gateA.reset(); gateB.reset();
        waitFor([&] { return oldA.expired() && oldB.expired(); }, "Previous workers did not shut down");
        a.packets.clear(); b.packets.clear(); dispatch();
        gateA = std::make_shared<Gate>(); gateB = std::make_shared<Gate>(); buildPeers();
        // Pause inside the first ACK operation, after it opens the source but before it queues FCEN.
        atB.clear(); first->start(registerClipboardFiles({large}), 0, 44);
        waitFor([&] { first->poll(); return !a.packets.empty(); }, "Missing stalled offer");
        // start() may first emit cancellation for the previous transfer; deliver up to FCBG.
        while (!a.packets.empty()) { bool offer = a.packets.front().compare(0, 4, "FCBG") == 0; pass(a, b, *second); if (offer) break; }
        waitFor([&] { second->poll(); return std::any_of(b.packets.begin(), b.packets.end(), [](const std::string& packet) { return packet.compare(0, 4, "FCAK") == 0; }); }, "Missing offer acknowledgement");
        gateA->arm();
        while (!b.packets.empty()) { bool ack = b.packets.front().compare(0, 4, "FCAK") == 0; if (ack) cancelledId = b.packets.front().substr(4, 4); pass(b, a, *first); if (ack) break; }
        gateA->waitBlocked();
        auto began = Clock::now(); first->poll(); ProtocolUtil::writef(&a, "CALV"); timely(began, "Input/network work blocked behind disk access");
        check(!a.packets.empty() && a.packets.back() == "CALV", "Heartbeat was not sent while disk stalled"); a.packets.pop_back();
        began = Clock::now(); first->cancel(); timely(began, "Cancel waited for disk access");
        check(std::any_of(a.packets.begin(), a.packets.end(), [](const std::string& packet) { return packet.compare(0, 4, "FCAB") == 0; }), "Cancel did not immediately notify peer");
        gateA->release();
        // A replacement copy must complete without publishing the cancelled generation.
        first->start(registerClipboardFiles({small}), 0, 45);
        waitFor([&] { pump(); check(atB.empty() || sequenceB == 45, "Stale clipboard was published after cancellation"); return !atB.empty(); }, "Transfer did not recover after cancellation");
        check(sameBytes(small, clipboardFiles(atB)->roots[0]), "Replacement clipboard differs");
        std::cout << "PASS: stalled worker leaves heartbeat/poll/cancel responsive; cancelled mid-operation output cannot escape or publish; next copy succeeds\n";

        // Destroy a receiver inside its offer operation, after it creates staging but before the ACK.
        Pipe doomedPipe; unsigned callbacks = 0; auto doomedGate = std::make_shared<Gate>(); doomedGate->arm();
        std::weak_ptr<Gate> workerLifetime = doomedGate;
        auto doomed = std::make_unique<AsyncFileClipboardTransfer>(&doomedPipe, [&](ClipboardID, uint32_t, const std::string&) { ++callbacks; }, nullptr, root / "doomed", makeHook(doomedGate));
        Pipe offer; ProtocolUtil::writef(&offer, "FCBG%4i%1i%4i", UInt32(123), ClipboardID(0), UInt32(99)); pass(offer, doomedPipe, *doomed); doomedGate->waitBlocked();
        began = Clock::now(); doomed.reset(); timely(began, "Disconnect/destruction waited for filesystem");
        doomedGate->release(); doomedGate.reset(); waitFor([&] { return workerLifetime.expired(); }, "Detached worker did not release its state");
        check(callbacks == 0 && doomedPipe.packets.empty(), "Destroyed connection produced a callback or packet");
        std::cout << "PASS: disconnect/destruction never waits for blocked worker; no callback or network access after destruction\n";
        // Wait for worker-owned receiver cleanup before deleting the test directory.
        std::weak_ptr<Gate> lifeA = gateA, lifeB = gateB;
        first.reset(); second.reset(); gateA.reset(); gateB.reset();
        waitFor([&] { return lifeA.expired() && lifeB.expired(); }, "Transfer workers did not shut down");
        // Native publication can fail or synchronously change the clipboard. Neither may
        // acknowledge a now-cancelled completion, escape the event loop, or use a worker thread.
        for (int mode : {0, 1, 2, 3}) {
            const bool throwOnPublish = (mode & 1) != 0, destroyOnPublish = mode >= 2;
            Pipe from, to; bool published = false;
            auto senderLife = std::make_shared<int>(1), receiverLife = std::make_shared<int>(1);
            std::weak_ptr<int> senderGone = senderLife, receiverGone = receiverLife;
            std::unique_ptr<AsyncFileClipboardTransfer> receiving;
            auto sending = std::make_unique<AsyncFileClipboardTransfer>(&from, [](ClipboardID, uint32_t, const std::string&) {}, &events,
                root / "callback-sender", [senderLife] {});
            receiving = std::make_unique<AsyncFileClipboardTransfer>(&to, [&](ClipboardID, uint32_t, const std::string&) {
                check(std::this_thread::get_id() == mainThread, "Native publication ran on worker");
                published = true; to.packets.clear();
                if (destroyOnPublish) { receiving.reset(); to.attached = false; }
                if (throwOnPublish) throw std::runtime_error("test native publication unavailable");
                if (!destroyOnPublish) receiving->cancel();
            }, &events, root / "callback-receiver", [receiverLife] {});
            sending->start(registerClipboardFiles({small}), 0, 50);
            waitFor([&] {
                dispatch();
                if (!published) { pass(from, to, *receiving); pass(to, from, *sending); }
                return published;
            }, "Publication callback was not reached");
            check(std::none_of(to.packets.begin(), to.packets.end(), [](const std::string& packet) { return packet.compare(0, 4, "FCAK") == 0; }),
                  "Stale completion ACK escaped after reentrant cancel/publication error");
            if (destroyOnPublish) check(!receiving && to.packets.empty() && !to.accessedAfterDetach, "Destroyed receiver produced a final ACK or network access");
            else check(std::any_of(to.packets.begin(), to.packets.end(), [](const std::string& packet) { return packet.compare(0, 4, "FCNO") == 0; }),
                       "Publication cancellation did not notify peer");
            sending.reset(); receiving.reset(); senderLife.reset(); receiverLife.reset();
            waitFor([&] { return senderGone.expired() && receiverGone.expired(); }, "Publication test worker did not stop");
            dispatch();
        }
        std::cout << "PASS: publication errors/reentrant cancel suppress stale ACK; receiver destruction (including throwing callback) has no later network access\n";
        // The worker has finished the file but not yet delivered native publication.
        // An abort received in that gap must invalidate the pending completion handle.
        {
            Pipe sourcePipe, destinationPipe; bool published = false;
            auto gate = std::make_shared<Gate>(); std::weak_ptr<Gate> gone = gate;
            auto destination = std::make_unique<AsyncFileClipboardTransfer>(&destinationPipe,
                [&](ClipboardID, uint32_t, const std::string&) { published = true; }, &events, root / "aborted-publication", makeHook(gate));
            FileClipboardTransfer sourceTransfer(&sourcePipe, [](ClipboardID, uint32_t, const std::string&) {}, root / "abort-sender");
            sourceTransfer.start(registerClipboardFiles({small}), 0, 60);
            waitFor([&] {
                dispatch();
                if (!sourcePipe.packets.empty() && sourcePipe.packets.front().compare(0, 4, "FCDN") == 0) return true;
                pass(sourcePipe, destinationPipe, *destination); pass(destinationPipe, sourcePipe, sourceTransfer); return false;
            }, "Sender did not reach pending publication");
            const auto id = sourcePipe.packets.front().substr(4, 4);
            gate->arm(); pass(sourcePipe, destinationPipe, *destination); gate->waitBlocked();
            check(!published, "Native publication escaped the worker gate");
            Pipe aborted; const auto packet = std::string("FCAB") + id; aborted.write(packet.data(), static_cast<UInt32>(packet.size()));
            pass(aborted, destinationPipe, *destination); gate->release();
            waitFor([&] { Event event; if (!events.getEvent(event, 0.0)) return false; events.dispatchEvent(event); Event::deleteData(event); return true; },
                    "Aborted pending publication did not return its worker result");
            dispatch(); check(!published && destinationPipe.packets.empty(), "Remote abort failed to suppress pending publication/final ACK");
            destination.reset(); gate.reset(); waitFor([&] { return gone.expired(); }, "Aborted publication worker did not stop"); dispatch();
        }
        std::cout << "PASS: completed transfers cancel silently; remote abort suppresses queued publication and final ACK\n";
        fs::remove_all(root); return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << "\nTest files: " << root.u8string() << '\n'; return 1; }
}
