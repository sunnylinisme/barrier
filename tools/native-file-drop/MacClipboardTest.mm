// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#include "platform/OSXClipboard.h"
#include "barrier/Clipboard.h"
#include "barrier/FileClipboardTransfer.h"
#include "io/IStream.h"
#include "arch/Arch.h"
#include "base/Log.h"
#include <deque>
#include <fstream>
#include <iostream>
#include <cstring>
#include <stdexcept>
using namespace barrier;
class MacPipe : public IStream {
public:
    std::deque<std::string> packets; std::string input;
    void write(const void* p, UInt32 n) override { if (n > 65560 || packets.size() > 1) throw std::runtime_error("unbounded queue"); packets.emplace_back(static_cast<const char*>(p), n); }
    UInt32 read(void* p, UInt32 n) override { n = std::min<UInt32>(n, input.size()); if (p) memcpy(p, input.data(), n); input.erase(0, n); return n; }
    UInt32 getSize() const override { return input.size(); } bool isReady() const override { return !input.empty(); }
    void* getEventTarget() const override { return nullptr; }
    void close() override {} void flush() override {} void shutdownInput() override {} void shutdownOutput() override {}
};
int main() {
    @autoreleasepool {
        Arch arch; arch.init(); Log log; log.setFilter(kWARNING);
        NSPasteboard* sourceBoard = [NSPasteboard pasteboardWithUniqueName];
        NSPasteboard* targetBoard = [NSPasteboard pasteboardWithUniqueName];
        auto root = fs::temp_directory_path() / std::string([[[NSUUID UUID] UUIDString] UTF8String]);
        try {
            fs::create_directories(root / "source");
            auto file = root / "source" / fs::u8path("Mac 大檔.bin");
            { std::ofstream out; open_utf8_path(out, file, std::ios::binary); out << 'A'; out.seekp(32 * 1024 * 1024); out << 'Z'; }
            auto folder = root / "source" / fs::u8path("空資料夾"); fs::create_directory(folder);
            [sourceBoard writeObjects:@[[NSURL fileURLWithPath:[NSString stringWithUTF8String:file.u8string().c_str()]], [NSURL fileURLWithPath:[NSString stringWithUTF8String:folder.u8string().c_str()]]]];
            OSXClipboard source(true, [[sourceBoard name] UTF8String]), target(true, [[targetBoard name] UTF8String]);
            Clipboard local; IClipboard::copy(&local, &source);
            if (!local.has(IClipboard::kFile)) throw std::runtime_error("Finder-compatible file URLs not captured");
            MacPipe a, b; bool complete = false;
            FileClipboardTransfer sender(&a, [](ClipboardID, uint32_t, const std::string&) {}, root / "unused");
            FileClipboardTransfer receiver(&b, [&](ClipboardID, uint32_t, const std::string& handle) {
                Clipboard incoming; incoming.open(0); incoming.add(IClipboard::kFile, handle); incoming.close();
                if (!IClipboard::copy(&target, &incoming)) throw std::runtime_error("Cannot publish received clipboard");
                complete = true;
            }, root / "cache");
            sender.start(local.get(IClipboard::kFile), 0, 42);
            for (int i = 0; i < 2000 && (!a.packets.empty() || !b.packets.empty()); ++i) {
                if (!a.packets.empty()) { auto p = a.packets.front(); a.packets.pop_front(); b.input = p.substr(4); if (!receiver.receive(reinterpret_cast<const unsigned char*>(p.data()))) throw std::runtime_error("unknown file packet"); }
                if (!b.packets.empty()) { auto p = b.packets.front(); b.packets.pop_front(); a.input = p.substr(4); if (!sender.receive(reinterpret_cast<const unsigned char*>(p.data()))) throw std::runtime_error("unknown ack"); }
            }
            NSArray* urls = [targetBoard readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
            if (!complete || sender.sending() || [urls count] != 2 || target.synchronize()) throw std::runtime_error("File clipboard missing or echoing itself");
            auto received = fs::u8path([[[urls objectAtIndex:0] path] UTF8String]);
            if (received == file || fs::file_size(received) != 32 * 1024 * 1024 + 1) throw std::runtime_error("File was not independently transferred");
            std::ifstream in; open_utf8_path(in, received, std::ios::binary); if (in.get() != 'A') throw std::runtime_error("Wrong first byte");
            in.seekg(32 * 1024 * 1024); if (in.get() != 'Z') throw std::runtime_error("Wrong last byte"); in.close();
            if (!fs::is_directory(fs::u8path([[[urls objectAtIndex:1] path] UTF8String]))) throw std::runtime_error("Folder missing");
            fs::remove_all(root); [sourceBoard releaseGlobally]; [targetBoard releaseGlobally];
            std::cout << "PASS: native macOS file URLs -> 32 MiB+1 streaming -> native file URLs, multiple items, Unicode folder, no clipboard echo\n";
            return 0;
        } catch (const std::exception& e) {
            std::cerr << e.what() << '\n'; std::error_code ec; fs::remove_all(root, ec);
            [sourceBoard releaseGlobally]; [targetBoard releaseGlobally]; return 1;
        }
    }
}
