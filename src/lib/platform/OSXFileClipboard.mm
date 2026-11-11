// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#include "OSXFileClipboard.h"
#include "barrier/FileClipboardTransfer.h"
#include <stdexcept>

static NSPasteboard* board(PasteboardRef reference) {
    CFStringRef name = nullptr;
    if (PasteboardCopyName(reference, &name) != noErr || !name) throw std::runtime_error("Cannot access file clipboard");
    NSPasteboard* result = CFEqual(name, kPasteboardClipboard) ? [NSPasteboard generalPasteboard] : [NSPasteboard pasteboardWithName:(NSString*)name];
    CFRelease(name); return result;
}
bool osxClipboardHasFiles(PasteboardRef reference) {
    @autoreleasepool {
        return [board(reference) canReadObjectForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    }
}
std::string osxClipboardGetFiles(PasteboardRef reference) {
    @autoreleasepool {
        NSArray* urls = [board(reference) readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
        std::vector<barrier::fs::path> paths;
        for (NSURL* url in urls) {
            const char* path = [[url path] UTF8String];
            if (!path) throw std::runtime_error("Unsupported source file name");
            paths.push_back(barrier::fs::u8path(path));
        }
        return barrier::registerClipboardFiles(paths);
    }
}
void osxClipboardPutFiles(PasteboardRef reference, const std::string& handle) {
    @autoreleasepool {
        auto files = barrier::clipboardFiles(handle);
        NSMutableArray* urls = [NSMutableArray array];
        for (const auto& path : files->roots) {
            NSString* name = [NSString stringWithUTF8String:path.u8string().c_str()];
            if (!name) throw std::runtime_error("Unsupported received file name");
            [urls addObject:[NSURL fileURLWithPath:name]];
        }
        NSPasteboard* target = board(reference); [target clearContents];
        if (![target writeObjects:urls]) throw std::runtime_error("Cannot publish received files to Finder");
        // Cocoa wrote the board; consume that change in the Carbon observer to avoid echoing it.
        PasteboardSynchronize(reference);
    }
}
