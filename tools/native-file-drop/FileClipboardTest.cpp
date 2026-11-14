// SPDX-License-Identifier: GPL-2.0-or-later
#include "barrier/FileClipboardTransfer.h"
#include "barrier/ProtocolUtil.h"
#include "io/IStream.h"
#include "arch/Arch.h"
#include "base/Log.h"
#include <chrono>
#include <deque>
#include <fstream>
#include <iostream>
#include <cstring>
#include <stdexcept>
#if SYSAPI_WIN32
#include "arch/win32/ArchMiscWindows.h"
#include <winioctl.h>
#endif
using namespace barrier;
static void check(bool value, const char* why) { if (!value) throw std::runtime_error(why); }
class Pipe : public IStream {
public:
    std::deque<std::string> packets; std::string input; size_t peak = 0;
    void write(const void* bytes, UInt32 count) override {
        check(count <= 65560, "unbounded protocol packet");
        packets.emplace_back(static_cast<const char*>(bytes), count);
        size_t pending = 0; for (const auto& p : packets) pending += p.size(); peak = std::max(peak, pending);
        check(pending <= 2 * 65560, "sender lacks backpressure");
    }
    UInt32 read(void* bytes, UInt32 count) override { count = std::min<UInt32>(count, input.size()); if (bytes) memcpy(bytes, input.data(), count); input.erase(0, count); return count; }
    UInt32 getSize() const override { return input.size(); }
    bool isReady() const override { return !input.empty(); }
    void* getEventTarget() const override { return nullptr; }
    void close() override {} void flush() override {} void shutdownInput() override {} void shutdownOutput() override {}
};
static void pass(Pipe& outgoing, Pipe& incoming, FileClipboardTransfer& target, bool corrupt = false) {
    auto packet = outgoing.packets.front(); outgoing.packets.pop_front();
    if (corrupt && packet.compare(0, 4, "FCHK") == 0) packet.back() ^= 1;
    incoming.input = packet.substr(4);
    check(target.receive(reinterpret_cast<const unsigned char*>(packet.data())), "unknown packet");
    check(incoming.input.empty(), "unconsumed packet");
}
static bool equalFiles(const fs::path& a, const fs::path& b) {
    if (fs::file_size(a) != fs::file_size(b)) return false;
    std::ifstream first, second; open_utf8_path(first, a, std::ios::binary); open_utf8_path(second, b, std::ios::binary);
    char x[65536], y[65536];
    while (first) { first.read(x, sizeof(x)); second.read(y, sizeof(y)); if (first.gcount() != second.gcount() || memcmp(x, y, first.gcount())) return false; }
    return first.eof() && second.eof();
}
int main() {
#if SYSAPI_WIN32
    ArchMiscWindows::setInstanceWin32(GetModuleHandle(nullptr));
#endif
    Arch arch; arch.init(); Log log; log.setFilter(kWARNING);
    auto root = fs::temp_directory_path() / ("file-clipboard-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        auto source = root / "source", cache = root / "cache"; fs::create_directories(source / fs::u8path("資料夾") / "empty");
        auto large = source / fs::u8path("大檔案.bin");
        { std::ofstream out; open_utf8_path(out, large, std::ios::binary); std::string bytes(65536, '\0');
          for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = char(i * 37);
          for (int i = 0; i < 1536; ++i) out.write(bytes.data(), bytes.size()); }
        auto nested = source / fs::u8path("資料夾") / fs::u8path("內容.txt");
        { std::ofstream out; open_utf8_path(out, nested, std::ios::binary); out << "nested contents"; }
        auto handle = registerClipboardFiles({large, source / fs::u8path("資料夾")});
        Pipe first, second; std::string received;
        FileClipboardTransfer sender(&first, [](ClipboardID, uint32_t, const std::string&) {}, root / "sender-cache");
        FileClipboardTransfer receiver(&second, [&](ClipboardID id, uint32_t sequence, const std::string& h) { check(id == 0 && sequence == 42, "clipboard identity lost"); received = h; }, cache);
        sender.start(handle, 0, 42);
        size_t messages = 0;
        while (!first.packets.empty() || !second.packets.empty()) {
            if (!first.packets.empty()) pass(first, second, receiver);
            if (!second.packets.empty()) pass(second, first, sender);
            check(++messages < 10000, "transfer did not terminate");
        }
        check(!sender.sending() && !received.empty(), "missing clipboard completion");
        auto files = clipboardFiles(received);
        check(files->roots.size() == 2 && equalFiles(large, files->roots[0]), "large file changed");
        check(equalFiles(nested, files->roots[1] / fs::u8path("內容.txt")) && fs::is_directory(files->roots[1] / "empty"), "folder transfer failed");
        check(first.peak < 70000 && second.peak < 70000, "large file buffered in memory");
        // An unchanged selection keeps its handle, so switching screens does not restart a transfer.
        auto again = registerClipboardFiles({nested});
        check(again == registerClipboardFiles({nested}), "unchanged selection got a new handle");
        { std::ofstream grow; open_utf8_path(grow, nested, std::ios::binary | std::ios::app); grow << "more"; }
        check(registerClipboardFiles({nested}) != again, "changed file kept the old handle");
        received.clear(); sender.start(registerClipboardFiles({nested}), 0, 42);
        while (!first.packets.empty() || !second.packets.empty()) {
            if (!first.packets.empty()) pass(first, second, receiver, true);
            if (!second.packets.empty()) pass(second, first, sender);
        }
        check(received.empty() && !sender.sending(), "damaged file published");
        sender.start(handle, 0, 42); pass(first, second, receiver); receiver.cancel();
        while (!first.packets.empty() || !second.packets.empty()) {
            if (!second.packets.empty()) pass(second, first, sender);
            if (!first.packets.empty()) pass(first, second, receiver);
        }
        check(!sender.sending() && received.empty(), "cancelled file published");
        for (const auto& path : fs::directory_iterator(cache)) check(path.path().extension() != ".partial", "partial transfer left behind");
        // A sparse source proves that sizes do not truncate at 4 GiB, without sending 4 GiB in CI.
        const auto huge = source / "over-4GiB.bin";
        const uint64_t hugeSize = (uint64_t(1) << 32) + 17;
#if SYSAPI_WIN32
        HANDLE sparse = CreateFileW(huge.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        check(sparse != INVALID_HANDLE_VALUE, "cannot create sparse source");
        DWORD returned = 0; LARGE_INTEGER end; end.QuadPart = hugeSize;
        bool sparseOk = DeviceIoControl(sparse, FSCTL_SET_SPARSE, nullptr, 0, nullptr, 0, &returned, nullptr) && SetFilePointerEx(sparse, end, nullptr, FILE_BEGIN) && SetEndOfFile(sparse);
        CloseHandle(sparse); check(sparseOk, "cannot size sparse source");
#else
        { std::ofstream out; open_utf8_path(out, huge, std::ios::binary); out.seekp(hugeSize - 1); out.put('x'); check(bool(out), "cannot create sparse source"); }
#endif
        sender.start(registerClipboardFiles({huge}), 0, 42);
        pass(first, second, receiver); pass(second, first, sender);
        check(first.packets.size() == 1 && first.packets.front().compare(0, 4, "FCEN") == 0, "missing large file header");
        first.input = first.packets.front().substr(4); first.packets.pop_front();
        UInt32 hugeId = 0; UInt8 hugeKind = 0; std::string hugePath, hugeLength;
        check(ProtocolUtil::readf(&first, "%4i%1i%s%s", &hugeId, &hugeKind, &hugePath, &hugeLength) && hugeLength == "4294967313", "file size truncated at 4 GiB");
        sender.cancel(); pass(first, second, receiver); receiver.cancel();
        check(received.empty(), "cancelled sparse source published");
        // A wire-supplied local capability and path traversal cannot access local files.
        bool rejected = false; try { clipboardFiles("FLOCAL2:untrusted"); } catch (...) { rejected = true; }
        check(rejected, "forged clipboard handle accepted");
        UInt32 id = 99; ProtocolUtil::writef(&first, "FCBG%4i%1i%4i", id, 0, 42); pass(first, second, receiver); second.packets.clear();
        std::string bad = "../escape", length = "0";
        ProtocolUtil::writef(&first, "FCEN%4i%1i%s%s", id, 1, &bad, &length); pass(first, second, receiver);
        check(!fs::exists(root / "escape") && received.empty(), "path traversal accepted");
        fs::remove_all(root);
        std::cout << "PASS: 96 MiB streamed with <=64 KiB queued, multiple items/folders, binary identity, over-4-GiB size header, corruption/cancel/traversal rejection\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; std::error_code ec; fs::remove_all(root, ec); return 1; }
}
