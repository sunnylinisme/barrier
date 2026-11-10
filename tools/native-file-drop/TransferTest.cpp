// SPDX-License-Identifier: GPL-2.0-or-later
#include "barrier/NativeFileProtocol.h"
#include "barrier/ProtocolUtil.h"
#include "io/IStream.h"
#include "arch/Arch.h"
#include "base/Log.h"
#include <algorithm>
#include <cstring>
#include <functional>
#include <iostream>
#include <fstream>
#include <chrono>
#include "io/filesystem.h"
#include <stdexcept>
#include <vector>
#if SYSAPI_WIN32
#include "arch/win32/ArchMiscWindows.h"
#endif

static void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static void rejects(std::function<void()> f) {
    bool rejected = false;
    try { f(); } catch (...) { rejected = true; }
    check(rejected, "invalid input accepted");
}
class MemoryStream : public barrier::IStream {
public:
    std::vector<std::string> packets;
    std::string input;
    void write(const void* p, UInt32 n) override { packets.emplace_back(static_cast<const char*>(p), n); }
    UInt32 read(void* p, UInt32 n) override {
        n = static_cast<UInt32>(std::min<std::size_t>(n, input.size()));
        if (p) memcpy(p, input.data(), n); input.erase(0, n); return n;
    }
    UInt32 getSize() const override { return static_cast<UInt32>(input.size()); }
    bool isReady() const override { return !input.empty(); }
    void* getEventTarget() const override { return nullptr; }
    void close() override {} void flush() override {}
    void shutdownInput() override {} void shutdownOutput() override {}
};
static std::shared_ptr<const barrier::NativeFile> receive(MemoryStream& stream, const std::string& packet,
                                                        uint32_t id, barrier::NativeFileReceiver& receiver) {
    check(packet.size() >= 4, "short test packet");
    stream.input = packet.substr(4);
    auto file = barrier::receiveNativeFile(&stream, reinterpret_cast<const unsigned char*>(packet.data()), id, receiver);
    check(stream.input.empty(), "unconsumed bytes"); return file;
}
int main(int argc, char** argv)
{
#if SYSAPI_WIN32
    ArchMiscWindows::setInstanceWin32(GetModuleHandle(nullptr));
#endif
    Arch arch; arch.init(); Log log; log.setFilter(kWARNING);
    try {
        if (argc == 3 && std::string(argv[1]) == "--wire-output") {
            barrier::NativeFile file{"跨機測試.txt", std::string("network snapshot\n\x00\x01\xff", 20)};
            MemoryStream stream; barrier::sendNativeFile(&stream, 42, file);
            std::ofstream out(argv[2], std::ios::binary);
            for (auto& packet : stream.packets) {
                auto n = static_cast<uint32_t>(packet.size());
                char length[] = {char(n >> 24), char(n >> 16), char(n >> 8), char(n)};
                out.write(length, 4); out.write(packet.data(), packet.size());
            }
            return out.good() ? 0 : 1;
        }
        auto directory = barrier::fs::temp_directory_path() / ("barrier-transfer-" +
            std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
        barrier::fs::create_directories(directory);
        try {
            auto path = directory / barrier::fs::u8path("真實來源.txt");
            { std::ofstream out; barrier::open_utf8_path(out, path, std::ios::binary); out << "actual file"; }
            auto snapshot = barrier::readNativeFile(path.u8string());
            check(snapshot->name == "真實來源.txt" && snapshot->bytes == "actual file", "real source snapshot");
            rejects([&] { barrier::readNativeFile(directory.u8string()); });
            rejects([&] { barrier::readNativeFile((directory / "missing").u8string()); });
            { std::ofstream out; barrier::open_utf8_path(out, path, std::ios::binary); }
            check(barrier::readNativeFile(path.u8string())->bytes.empty(), "empty source file");
            { std::ofstream out; barrier::open_utf8_path(out, path, std::ios::binary);
              out.seekp(barrier::nativeFileLimit); out.put('x'); }
            rejects([&] { barrier::readNativeFile(path.u8string()); });
#if !SYSAPI_WIN32
            auto link = directory / "link";
            barrier::fs::create_symlink(path, link);
            rejects([&] { barrier::readNativeFile(link.u8string()); });
#endif
        } catch (...) { barrier::fs::remove_all(directory); throw; }
        barrier::fs::remove_all(directory);
        for (auto name : {"../bad", "a/b", "a\\b", "x:stream", "CON", "LPT1.txt", "COM².txt", "NUL .txt", "trailing.", "trailing ", "..", "", "bad?"})
            check(!barrier::nativeFilenameValid(name), "invalid filename accepted");
        check(!barrier::nativeFilenameValid(std::string("nul\0name", 8)), "NUL filename");
        check(!barrier::nativeFilenameValid("\xc0\xaf"), "overlong UTF-8");
        check(!barrier::nativeFilenameValid("\xed\xa0\x80"), "UTF-8 surrogate");
        check(!barrier::nativeFilenameValid("\xf4\x90\x80\x80"), "UTF-8 range");
        check(barrier::nativeFilenameValid("測試-😀.bin"), "valid Unicode rejected");
        for (std::size_t size : {std::size_t(0), std::size_t(131137), barrier::nativeFileLimit}) {
            barrier::NativeFile source{"測試-😀.bin", std::string(size, '\0')};
            for (std::size_t i = 0; i < size; ++i) source.bytes[i] = static_cast<char>(i * 19);
            MemoryStream stream; barrier::sendNativeFile(&stream, 42, source);
            barrier::NativeFileReceiver receiver;
            std::shared_ptr<const barrier::NativeFile> result;
            for (auto& packet : stream.packets) {
                check(packet.size() < 128 * 1024, "unbounded wire packet");
                auto file = receive(stream, packet, 42, receiver);
                if (file) result = file;
            }
            check(result && result->name == source.name && result->bytes == source.bytes, "wire roundtrip mismatch");
            rejects([&] { receive(stream, stream.packets.back(), 42, receiver); });
        }
        barrier::NativeFile source{"安全.txt", "real\nfile bytes"};
        MemoryStream stream; barrier::sendNativeFile(&stream, 42, source);
        barrier::NativeFileReceiver receiver;
        rejects([&] { receive(stream, stream.packets[0], 41, receiver); });
        receive(stream, stream.packets[0], 42, receiver);
        rejects([&] { receive(stream, stream.packets[0], 42, receiver); });
        receive(stream, stream.packets[0], 42, receiver);
        rejects([&] { receive(stream, stream.packets.back(), 42, receiver); });
        receive(stream, stream.packets[0], 42, receiver);
        auto corrupt = stream.packets[1]; corrupt.back() ^= 1;
        receive(stream, corrupt, 42, receiver);
        rejects([&] { receive(stream, stream.packets.back(), 42, receiver); });
        receive(stream, stream.packets[0], 42, receiver);
        rejects([&] { receive(stream, stream.packets[1].substr(0, 10), 42, receiver); });
        receive(stream, stream.packets[0], 42, receiver);
        receiver.reset(); // disconnect / leave clears ownership
        rejects([&] { receive(stream, stream.packets[1], 42, receiver); });
        rejects([&] { receiver.begin(1, barrier::nativeFileLimit + 1, "a", barrier::nativeDigest("")); });
        receiver.begin(1, 1, "a", barrier::nativeDigest("a"));
        rejects([&] { receiver.append(1, "aa"); });
        receiver.begin(1, barrier::nativeFileLimit, "a", barrier::nativeDigest("a"));
        rejects([&] { receiver.append(1, std::string(barrier::nativeChunkLimit + 1, 'a')); });
        std::cout << "PASS: production wire roundtrip (empty/binary/16 MiB), Unicode, limits, corruption, stale IDs, truncation, reset\n";
    } catch (const std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
}
