// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "barrier/NativeFileTransfer.h"
#include <atomic>
#include <thread>

struct NativeDragState {
    std::atomic<bool> pressed{true}, cancelled{false}, done{false};
};
class MSWindowsNativeDrag {
public:
    ~MSWindowsNativeDrag();
    void start(std::shared_ptr<const barrier::NativeFile> file);
    bool release();
    void cancel();
private:
    std::shared_ptr<NativeDragState> state_;
    std::thread worker_;
};
