// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "FileClipboardTransfer.h"
#include "base/Event.h"
class IEventQueue;
namespace barrier {
// Disk operations never run on the input/network event thread. The wire protocol is unchanged.
class AsyncFileClipboardTransfer {
public:
    AsyncFileClipboardTransfer(IStream*, FileClipboardTransfer::Completed, IEventQueue*,
                               const fs::path& cache = {}, std::function<void()> beforeOutput = {});
    ~AsyncFileClipboardTransfer();
    void start(const std::string&, ClipboardID, uint32_t);
    bool receive(const unsigned char*);
    void cancel();
    void poll(); // Also usable by integration tests without an OS event queue.
    static void finishShutdown(int exitCode); // Call before destroying app/queue/log globals.
private:
    struct State;
    std::shared_ptr<State> state_;
    IStream* stream_;
    FileClipboardTransfer::Completed completed_;
    IEventQueue* events_;
    uint32_t outgoing_ = 0, incoming_ = 0;
    void ready(const Event&, void*);
};
}
