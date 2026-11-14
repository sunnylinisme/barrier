// SPDX-License-Identifier: GPL-2.0-or-later
#include "FileClipboardTransfer.h"
#include "NativeFileTransfer.h"
#include "ProtocolUtil.h"
#include "common/DataDirectories.h"
#include "base/Log.h"
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <deque>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>

namespace barrier {
namespace {
constexpr size_t chunkSize = 64 * 1024;
constexpr const char* begin = "FCBG%4i%1i%4i";
constexpr const char* entry = "FCEN%4i%1i%s%s";
constexpr const char* chunk = "FCHK%4i%s";
constexpr const char* fileEnd = "FCFE%4i%s";
constexpr const char* done = "FCDN%4i";
constexpr const char* ack = "FCAK%4i%4i";
constexpr const char* abort = "FCAB%4i";
constexpr const char* rejected = "FCNO%4i%s";
std::mutex registryMutex;
std::map<std::string, std::shared_ptr<const ClipboardFiles>> registry;
std::deque<std::string> history;
// Selection (paths, sizes, modification times) -> handle, so reading an unchanged
// clipboard again yields the same handle. Otherwise every screen switch looked like a
// new copy to the server, which cancelled and restarted a transfer still in progress.
std::map<std::string, std::string> handleBySelection;
std::string randomName() {
    unsigned char bytes[16];
    if (RAND_bytes(bytes, sizeof(bytes)) != 1) throw std::runtime_error("Cannot create transfer identity");
    const char* hex = "0123456789abcdef"; std::string result;
    for (auto b : bytes) { result += hex[b >> 4]; result += hex[b & 15]; }
    return result;
}
uint64_t number(const std::string& value) {
    if (value.empty() || value.size() > 20) throw std::runtime_error("Invalid file size");
    uint64_t result = 0;
    for (char c : value) {
        if (c < '0' || c > '9' || result > (UINT64_MAX - (c - '0')) / 10) throw std::runtime_error("Invalid file size");
        result = result * 10 + (c - '0');
    }
    return result;
}
void safeRelative(const std::string& path) {
    if (path.empty() || path.size() > 32768) throw std::runtime_error("Unsupported file path");
    size_t start = 0, depth = 0;
    while (start < path.size()) {
        auto slash = path.find('/', start);
        auto name = path.substr(start, slash == std::string::npos ? slash : slash - start);
        if (!nativeFilenameValid(name) || ++depth > 128) throw std::runtime_error("Unsupported file name or folder depth");
        if (slash == std::string::npos) return;
        start = slash + 1;
    }
    throw std::runtime_error("Invalid trailing path separator");
}
// Throttled progress line; the desktop apps read it from the log to show the transferred size and speed.
void progress(const char* verb, uint64_t total, std::chrono::steady_clock::time_point& last) {
    auto now = std::chrono::steady_clock::now();
    if (now - last < std::chrono::milliseconds(500)) return;
    last = now;
    LOG((CLOG_INFO "file clipboard: progress %s %s bytes", verb, std::to_string(total).c_str()));
}
struct Digest {
    EVP_MD_CTX* context = EVP_MD_CTX_new();
    Digest() { if (!context || EVP_DigestInit_ex(context, EVP_sha256(), nullptr) != 1) { EVP_MD_CTX_free(context); throw std::runtime_error("Cannot initialize SHA-256"); } }
    ~Digest() { EVP_MD_CTX_free(context); }
    void add(const std::string& bytes) { if (EVP_DigestUpdate(context, bytes.data(), bytes.size()) != 1) throw std::runtime_error("Cannot hash file"); }
    std::string finish() {
        unsigned char value[EVP_MAX_MD_SIZE]; unsigned length = 0;
        if (EVP_DigestFinal_ex(context, value, &length) != 1 || length != 32) throw std::runtime_error("Cannot finish SHA-256");
        return std::string(reinterpret_cast<char*>(value), length);
    }
};
}

std::string registerClipboardFiles(const std::vector<fs::path>& paths) {
    if (paths.empty() || paths.size() > 4096) throw std::runtime_error("Select between 1 and 4096 files or folders");
    auto files = std::make_shared<ClipboardFiles>(); std::set<std::string> names;
    for (const auto& path : paths) {
        auto absolute = fs::absolute(path).lexically_normal();
        auto name = absolute.filename().u8string(); safeRelative(name);
        // File type/existence is validated by the disk worker immediately before opening.
        std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return c < 128 ? std::tolower(c) : c; });
        if (!names.insert(name).second) throw std::runtime_error("Selected items have conflicting names");
        files->roots.push_back(absolute);
    }
    std::string selection;
    for (const auto& root : files->roots) {
        std::error_code ec;
        auto modified = fs::last_write_time(root, ec).time_since_epoch().count();
        auto size = fs::is_regular_file(root, ec) ? fs::file_size(root, ec) : 0;
        selection += root.u8string() + '\n' + std::to_string(modified) + ' ' + std::to_string(size) + '\n';
    }
    std::lock_guard<std::mutex> lock(registryMutex);
    auto known = handleBySelection.find(selection);
    if (known != handleBySelection.end() && registry.count(known->second)) return known->second;
    auto handle = "FLOCAL2:" + randomName();
    registry[handle] = files; history.push_back(handle); handleBySelection[selection] = handle;
    while (history.size() > 32) {
        registry.erase(history.front()); history.pop_front();
        for (auto i = handleBySelection.begin(); i != handleBySelection.end();) i = registry.count(i->second) ? std::next(i) : handleBySelection.erase(i);
    }
    return handle;
}
std::shared_ptr<const ClipboardFiles> clipboardFiles(const std::string& handle) {
    std::lock_guard<std::mutex> lock(registryMutex);
    auto found = registry.find(handle);
    if (found == registry.end()) throw std::runtime_error("File clipboard expired; copy the selection again");
    return found->second;
}

struct FileClipboardTransfer::Impl {
    IStream* stream; Completed completed; fs::path cache;
    struct Sender {
        uint32_t id; ClipboardID clipboard; uint32_t sequence, packet = 0;
        std::shared_ptr<const ClipboardFiles> files;
        size_t root = 0;
        std::unique_ptr<fs::recursive_directory_iterator> iterator;
        std::ifstream input; std::unique_ptr<Digest> digest;
        fs::path path; uint64_t size = 0, sent = 0, total = 0;
        fs::file_time_type modified;
        std::chrono::steady_clock::time_point reported = std::chrono::steady_clock::now();
        bool endingFile = false, endingTransfer = false;
        bool next(fs::path& absolute, std::string& relative) {
            if (iterator) {
                if (*iterator != fs::recursive_directory_iterator{}) {
                    if (iterator->depth() > 126) throw std::runtime_error("Folder nesting is too deep");
                    absolute = (**iterator).path();
                    relative = (files->roots[root].filename() / absolute.lexically_relative(files->roots[root])).generic_u8string();
                    ++*iterator; return true;
                }
                iterator.reset(); ++root;
            }
            if (root == files->roots.size()) return false;
            absolute = files->roots[root]; relative = absolute.filename().u8string();
            if (fs::is_directory(fs::symlink_status(absolute))) iterator.reset(new fs::recursive_directory_iterator(absolute));
            else ++root;
            return true;
        }
    };
    struct Receiver {
        uint32_t id; ClipboardID clipboard; uint32_t sequence, packet = 0;
        fs::path directory, current; std::vector<fs::path> roots;
        std::ofstream output; std::unique_ptr<Digest> digest;
        uint64_t size = 0, received = 0, total = 0; size_t entries = 0;
        std::chrono::steady_clock::time_point reported = std::chrono::steady_clock::now();
        bool committed = false;
        ~Receiver() { output.close(); if (!committed) { std::error_code ec; fs::remove_all(directory, ec); } }
    };
    std::unique_ptr<Sender> tx;
    std::unique_ptr<Receiver> rx;
    Impl(IStream* s, Completed c, fs::path p) : stream(s), completed(std::move(c)), cache(std::move(p)) {}
    void advance() {
        auto& s = *tx;
        if (s.endingTransfer) { LOG((CLOG_INFO "file clipboard: sent %s bytes", std::to_string(s.total).c_str())); tx.reset(); return; }
        if (s.endingFile) { s.input.close(); s.digest.reset(); s.endingFile = false; }
        if (s.input.is_open()) {
            if (s.sent < s.size) {
                std::string bytes(static_cast<size_t>(std::min<uint64_t>(chunkSize, s.size - s.sent)), '\0');
                if (!s.input.read(&bytes[0], bytes.size())) throw std::runtime_error("Source file changed or became unreadable");
                s.digest->add(bytes); s.sent += bytes.size(); s.total += bytes.size(); progress("sent", s.total, s.reported);
                ProtocolUtil::writef(stream, chunk, s.id, &bytes); return;
            }
            if (s.input.peek() != EOF || fs::last_write_time(s.path) != s.modified || fs::file_size(s.path) != s.size)
                throw std::runtime_error("Source file changed while copying; copy again");
            auto hash = s.digest->finish(); s.endingFile = true;
            ProtocolUtil::writef(stream, fileEnd, s.id, &hash); return;
        }
        fs::path path; std::string relative;
        if (!s.next(path, relative)) { s.endingTransfer = true; ProtocolUtil::writef(stream, done, s.id); return; }
        safeRelative(relative);
        auto status = fs::symlink_status(path);
        UInt8 kind = fs::is_directory(status) ? 2 : 1;
        if (kind == 1 && !fs::is_regular_file(status)) throw std::runtime_error("Links and special files are not supported");
        std::string length = "0";
        if (kind == 1) {
            s.path = path; s.size = fs::file_size(path); s.sent = 0; s.modified = fs::last_write_time(path);
            open_utf8_path(s.input, path, std::ios::binary);
            if (!s.input) throw std::runtime_error("Cannot open source file");
            s.digest.reset(new Digest); length = std::to_string(s.size);
        }
        ProtocolUtil::writef(stream, entry, s.id, kind, &relative, &length);
    }
    void cancel() {
        if (tx) { ProtocolUtil::writef(stream, abort, tx->id); tx.reset(); }
        if (rx) { std::string reason = "Clipboard changed or transfer cancelled"; ProtocolUtil::writef(stream, rejected, rx->id, &reason); rx.reset(); }
    }
};

FileClipboardTransfer::FileClipboardTransfer(IStream* stream, Completed c, const fs::path& cache) :
    impl_(new Impl(stream, std::move(c), cache.empty() ? DataDirectories::profile() / "FileClipboardCache" : cache)) {}
FileClipboardTransfer::~FileClipboardTransfer() = default;
bool FileClipboardTransfer::sending() const { return !!impl_->tx; }
void FileClipboardTransfer::cancel() { impl_->cancel(); }
void FileClipboardTransfer::start(const std::string& handle, ClipboardID clipboard, uint32_t sequence) {
    auto& p = *impl_; p.cancel();
    auto source = clipboardFiles(handle);
    auto sender = std::make_unique<Impl::Sender>();
    if (RAND_bytes(reinterpret_cast<unsigned char*>(&sender->id), sizeof(sender->id)) != 1) throw std::runtime_error("Cannot create transfer ID");
    if (!sender->id) sender->id = 1;
    sender->files = source; sender->clipboard = clipboard; sender->sequence = sequence;
    p.tx = std::move(sender);
    LOG((CLOG_INFO "file clipboard: sending %u selected items", static_cast<unsigned>(source->roots.size())));
    ProtocolUtil::writef(p.stream, begin, p.tx->id, clipboard, sequence);
}
bool FileClipboardTransfer::receive(const unsigned char* code) {
    if (memcmp(code, "FC", 2) != 0) return false;
    auto& p = *impl_; UInt32 id = 0, acknowledgement = 0;
    const bool senderMessage = memcmp(code, ack, 4) == 0 || memcmp(code, rejected, 4) == 0;
    try {
        if (memcmp(code, ack, 4) == 0) {
            UInt32 counter = 0;
            if (!ProtocolUtil::readf(p.stream, ack + 4, &id, &counter)) throw std::runtime_error("Invalid file acknowledgement");
            if (p.tx && p.tx->id == id && counter == p.tx->packet) { ++p.tx->packet; p.advance(); }
            return true;
        }
        if (memcmp(code, rejected, 4) == 0) {
            std::string reason;
            if (!ProtocolUtil::readf(p.stream, rejected + 4, &id, &reason)) throw std::runtime_error("Invalid file rejection");
            if (p.tx && p.tx->id == id) { LOG((CLOG_WARN "file clipboard: receiver rejected transfer: %.200s", reason.c_str())); p.tx.reset(); }
            return true;
        }
        if (memcmp(code, abort, 4) == 0) {
            if (!ProtocolUtil::readf(p.stream, abort + 4, &id)) throw std::runtime_error("Invalid file cancellation");
            if (p.rx && p.rx->id == id) p.rx.reset();
            return true;
        }
        if (memcmp(code, begin, 4) == 0) {
            ClipboardID clipboard = 0; UInt32 sequence = 0;
            if (!ProtocolUtil::readf(p.stream, begin + 4, &id, &clipboard, &sequence) || !id || clipboard != kClipboardClipboard)
                throw std::runtime_error("Invalid file clipboard offer");
            p.rx.reset();
            auto receive = std::make_unique<Impl::Receiver>(); receive->id = id; receive->clipboard = clipboard; receive->sequence = sequence;
            fs::create_directories(p.cache);
#if !SYSAPI_WIN32
            fs::permissions(p.cache, fs::perms::owner_all, fs::perm_options::replace);
#endif
            receive->directory = p.cache / (randomName() + ".partial");
            if (!fs::create_directory(receive->directory)) throw std::runtime_error("Cannot create receive directory");
#if !SYSAPI_WIN32
            fs::permissions(receive->directory, fs::perms::owner_all, fs::perm_options::replace);
#endif
            p.rx = std::move(receive);
            LOG((CLOG_INFO "file clipboard: receiving files"));
        } else if (memcmp(code, entry, 4) == 0) {
            UInt8 kind = 0; std::string relative, length;
            if (!ProtocolUtil::readf(p.stream, entry + 4, &id, &kind, &relative, &length)) throw std::runtime_error("Invalid file entry");
            if (!p.rx || id != p.rx->id || p.rx->output.is_open()) throw std::runtime_error("Unexpected file entry");
            auto& r = *p.rx; safeRelative(relative); auto size = number(length);
            if ((kind != 1 && kind != 2) || (kind == 2 && size != 0) || ++r.entries > 1000000) throw std::runtime_error("Invalid entry type or too many entries");
            auto path = r.directory / fs::u8path(relative);
            if (!fs::is_directory(path.parent_path()) || fs::exists(path)) throw std::runtime_error("Conflicting file names or missing parent folder");
            if (relative.find('/') == std::string::npos) {
                if (r.roots.size() == 4096) throw std::runtime_error("Too many selected items");
                r.roots.push_back(fs::u8path(relative));
            }
            if (kind == 2) fs::create_directory(path);
            else {
                if (fs::space(r.directory).available < size) throw std::runtime_error("Not enough disk space for this file");
                open_utf8_path(r.output, path, std::ios::binary);
                if (!r.output) throw std::runtime_error("Cannot create received file");
                r.current = path; r.size = size; r.received = 0; r.digest.reset(new Digest);
            }
        } else if (memcmp(code, chunk, 4) == 0) {
            std::string bytes;
            if (!ProtocolUtil::readf(p.stream, chunk + 4, &id, &bytes)) throw std::runtime_error("Invalid file chunk");
            if (!p.rx || id != p.rx->id || !p.rx->output.is_open() || bytes.empty() || bytes.size() > chunkSize || bytes.size() > p.rx->size - p.rx->received)
                throw std::runtime_error("Unexpected or oversized file chunk");
            auto& r = *p.rx; r.output.write(bytes.data(), bytes.size());
            if (!r.output) throw std::runtime_error("Cannot write received file; check disk space");
            r.digest->add(bytes); r.received += bytes.size(); r.total += bytes.size(); progress("received", r.total, r.reported);
        } else if (memcmp(code, fileEnd, 4) == 0) {
            std::string hash;
            if (!ProtocolUtil::readf(p.stream, fileEnd + 4, &id, &hash)) throw std::runtime_error("Invalid file completion");
            if (!p.rx || id != p.rx->id || !p.rx->output.is_open() || p.rx->received != p.rx->size || hash.size() != 32 || p.rx->digest->finish() != hash)
                throw std::runtime_error("Received file is incomplete or checksum differs");
            p.rx->output.close();
            if (!p.rx->output) throw std::runtime_error("Cannot finish received file");
            p.rx->digest.reset();
        } else if (memcmp(code, done, 4) == 0) {
            if (!ProtocolUtil::readf(p.stream, done + 4, &id)) throw std::runtime_error("Invalid clipboard completion");
            if (!p.rx || id != p.rx->id || p.rx->output.is_open() || p.rx->roots.empty()) throw std::runtime_error("Incomplete clipboard transfer");
            auto& r = *p.rx;
            acknowledgement = r.packet;
            auto complete = p.cache / randomName(); fs::rename(r.directory, complete); r.directory = complete;
            std::vector<fs::path> roots; for (const auto& root : r.roots) roots.push_back(complete / root);
            auto handle = registerClipboardFiles(roots);
            p.completed(r.clipboard, r.sequence, handle); r.committed = true;
            LOG((CLOG_INFO "file clipboard: received and verified %s bytes; %u items ready to paste", std::to_string(r.total).c_str(), static_cast<unsigned>(roots.size())));
            p.rx.reset();
        } else return false;
        if (p.rx) acknowledgement = p.rx->packet++;
        ProtocolUtil::writef(p.stream, ack, id, acknowledgement);
    } catch (const std::exception& e) {
        std::string reason = e.what(); LOG((CLOG_WARN "file clipboard: %s", reason.c_str()));
        if (senderMessage) { if (p.tx) ProtocolUtil::writef(p.stream, abort, p.tx->id); p.tx.reset(); }
        else { ProtocolUtil::writef(p.stream, rejected, id, &reason); p.rx.reset(); }
    }
    return true;
}
}
