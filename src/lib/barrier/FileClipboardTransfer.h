// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "io/filesystem.h"
#include "barrier/clipboard_types.h"
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace barrier {
class IStream;
struct ClipboardFiles { std::vector<fs::path> roots; };
// Handles are process-local capabilities. They are never accepted from the wire.
std::string registerClipboardFiles(const std::vector<fs::path>& paths);
std::shared_ptr<const ClipboardFiles> clipboardFiles(const std::string& handle);
constexpr const char* fileClipboardCapability = "FCAP%4i";

class FileClipboardTransfer {
public:
    using Completed = std::function<void(ClipboardID, uint32_t, const std::string&)>;
    FileClipboardTransfer(IStream*, Completed, const fs::path& cache = {});
    ~FileClipboardTransfer();
    void start(const std::string& handle, ClipboardID, uint32_t sequence);
    bool receive(const unsigned char* code);
    void cancel();
    bool sending() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
