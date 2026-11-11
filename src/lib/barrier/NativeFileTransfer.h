// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <memory>
#include <string>

namespace barrier {
// shortcut: one in-memory file <=16 MiB; add streaming before increasing this limit.
constexpr std::size_t nativeFileLimit = 16 * 1024 * 1024;
constexpr std::size_t nativeChunkLimit = 64 * 1024;
constexpr char nativeCapability[] = "CNDF%4i";
constexpr char nativeBegin[] = "NDFB%4i%4i%s%s";
constexpr char nativeChunk[] = "NDFC%4i%s";
constexpr char nativeEnd[] = "NDFE%4i";
struct NativeFile { std::string name, bytes; };
bool nativeFilenameValid(const std::string& name);
std::string nativeDigest(const std::string& bytes);
std::shared_ptr<const NativeFile> readNativeFile(const std::string& path);
std::string encodeClipboardFile(const NativeFile& file);
std::shared_ptr<const NativeFile> decodeClipboardFile(const std::string& data);
class NativeFileReceiver {
public:
    void begin(uint32_t id, uint32_t size, const std::string& name, const std::string& digest);
    void append(uint32_t id, const std::string& bytes);
    std::shared_ptr<const NativeFile> finish(uint32_t id);
    void reset();
private:
    std::shared_ptr<NativeFile> file_;
    uint32_t id_ = 0, size_ = 0;
    std::string digest_;
};
}
