// SPDX-License-Identifier: GPL-2.0-or-later
#import <Cocoa/Cocoa.h>
#include "Sample.h"
#include <cstdio>
#include <cstring>

@interface ProbeView : NSView <NSDraggingSource, NSFilePromiseProviderDelegate>
@property(strong) NSOperationQueue* writerQueue;
@property(copy) NSString* status;
@end

@implementation ProbeView
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _writerQueue = [NSOperationQueue new];
        _writerQueue.maxConcurrentOperationCount = 1;
        _status = @"Drag the file below into a Finder folder.";
    }
    return self;
}
- (void)drawRect:(NSRect)rect
{
    (void)rect;
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(self.bounds);
    NSDictionary* attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:15],
                             NSForegroundColorAttributeName: [NSColor labelColor]};
    [@"Barrier — native drop preview" drawAtPoint:NSMakePoint(24, 212) withAttributes:attrs];
    [@"Local receiver test • no network connection yet" drawAtPoint:NSMakePoint(24, 182) withAttributes:attrs];
    [[NSColor controlBackgroundColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(24, 84, 470, 72)
                                    xRadius:8 yRadius:8] fill];
    [[NSString stringWithUTF8String:sampleName()] drawAtPoint:NSMakePoint(40, 112) withAttributes:attrs];
    [self.status drawInRect:NSMakeRect(24, 16, 470, 52) withAttributes:attrs];
}
- (void)mouseDown:(NSEvent*)event
{
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(point, NSMakeRect(24, 84, 470, 72))) return;
    NSFilePromiseProvider* provider = [[NSFilePromiseProvider alloc]
        initWithFileType:@"public.utf8-plain-text" delegate:self];
    NSDraggingItem* item = [[NSDraggingItem alloc] initWithPasteboardWriter:provider];
    NSImage* icon = [[NSWorkspace sharedWorkspace] iconForFileType:@"txt"];
    [item setDraggingFrame:NSMakeRect(point.x - 16, point.y - 16, 32, 32) contents:icon];
    [self beginDraggingSessionWithItems:@[item] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession*)session
        sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    (void)session;
    (void)context;
    return NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession*)session endedAtPoint:(NSPoint)point
        operation:(NSDragOperation)operation
{
    (void)session;
    (void)point;
    // Successful promises report their write result from the background queue.
    if (operation == NSDragOperationNone) {
        self.status = @"Drag cancelled; no file was delivered.";
        [self setNeedsDisplay:YES];
    }
}
- (NSString*)filePromiseProvider:(NSFilePromiseProvider*)provider fileNameForType:(NSString*)type
{
    (void)provider;
    (void)type;
    return [NSString stringWithUTF8String:sampleName()];
}
- (NSOperationQueue*)operationQueueForFilePromiseProvider:(NSFilePromiseProvider*)provider
{
    (void)provider;
    return self.writerQueue;
}
- (void)filePromiseProvider:(NSFilePromiseProvider*)provider writePromiseToURL:(NSURL*)url
        completionHandler:(void (^)(NSError*))completionHandler
{
    (void)provider;
    // The destination supplies the complete URL, including any collision rename.
    // No staging file or desktop fallback: only this requested destination is written.
    std::string bytes = sampleContent();
    NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    NSError* error = nil;
    [data writeToURL:url options:NSDataWritingWithoutOverwriting error:&error];
    completionHandler(error);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = error ? [@"Write failed: " stringByAppendingString:error.localizedDescription]
                            : [@"Saved: " stringByAppendingString:url.lastPathComponent];
        [self setNeedsDisplay:YES];
    });
}
@end

static int selfTest()
{
    ProbeView* view = [[ProbeView alloc] initWithFrame:NSZeroRect];
    NSFilePromiseProvider* provider = [[NSFilePromiseProvider alloc]
        initWithFileType:@"public.utf8-plain-text" delegate:view];
    NSURL* dir = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError* error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir
            withIntermediateDirectories:NO attributes:nil error:&error]) return 1;
    NSString* name = [view filePromiseProvider:provider fileNameForType:provider.fileType];
    NSURL* file = [dir URLByAppendingPathComponent:name];
    __block int calls = 0;
    __block BOOL wrote = NO;
    [[view operationQueueForFilePromiseProvider:provider] addOperationWithBlock:^{
        [view filePromiseProvider:provider writePromiseToURL:file completionHandler:^(NSError* e) {
            ++calls;
            wrote = (e == nil);
        }];
    }];
    [view.writerQueue waitUntilAllOperationsAreFinished];
    std::string expected = sampleContent();
    NSData* bytes = [NSData dataWithContentsOfURL:file];
    BOOL passed = calls == 1 && wrote && bytes.length == expected.size() &&
        memcmp(bytes.bytes, expected.data(), expected.size()) == 0;
    NSData* sentinel = [@"existing user data" dataUsingEncoding:NSUTF8StringEncoding];
    passed = passed && [sentinel writeToURL:file options:NSDataWritingAtomic error:nil];
    __block BOOL refused = NO;
    [view filePromiseProvider:provider writePromiseToURL:file completionHandler:^(NSError* e) {
        refused = e != nil;
    }];
    passed = passed && refused && [[NSData dataWithContentsOfURL:file] isEqual:sentinel];
    NSURL* absent = [[dir URLByAppendingPathComponent:@"missing" isDirectory:YES]
        URLByAppendingPathComponent:name];
    __block BOOL failed = NO;
    [view filePromiseProvider:provider writePromiseToURL:absent completionHandler:^(NSError* e) {
        failed = e != nil;
    }];
    passed = passed && failed;
    [[NSFileManager defaultManager] removeItemAtURL:dir error:nil];
    std::puts(passed ? "PASS: promise delivery, UTF-8, no overwrite, write failure"
                     : "FAIL: native promise contract");
    return passed ? 0 : 1;
}

@interface ProbeApp : NSObject <NSApplicationDelegate>
@property(strong) NSWindow* window;
@end
@implementation ProbeApp
- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    (void)notification;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 260)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Barrier Drop Probe — development preview";
    self.window.contentView = [[ProbeView alloc] initWithFrame:NSMakeRect(0, 0, 520, 260)];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
    (void)sender;
    return YES;
}
@end

int main(int argc, const char* argv[])
{
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return selfTest();
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        ProbeApp* delegate = [ProbeApp new];
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
