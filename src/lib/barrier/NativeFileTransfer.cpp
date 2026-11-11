// SPDX-License-Identifier: GPL-2.0-or-later
#include "NativeFileTransfer.h"
#include "io/filesystem.h"
#include <openssl/sha.h>
#include <algorithm>
#include <fstream>
#include <stdexcept>

namespace barrier {
bool nativeFilenameValid(const std::string& name)
{
    if (name.empty() || name.size() > 240 || name.back() == '.' || name.back() == ' ') return false;
    // Decode UTF-8 strictly; reject Windows separators, ADS, controls and device names.
    for (std::size_t i = 0; i < name.size();) {
        uint32_t c = static_cast<unsigned char>(name[i++]);
        unsigned continuation = 0;
        uint32_t minimum = 0;
        if (c >= 0xC2 && c <= 0xDF) { c &= 31; continuation = 1; minimum = 0x80; }
        else if (c >= 0xE0 && c <= 0xEF) { c &= 15; continuation = 2; minimum = 0x800; }
        else if (c >= 0xF0 && c <= 0xF4) { c &= 7; continuation = 3; minimum = 0x10000; }
        else if (c >= 0x80) return false;
        for (unsigned j = 0; j < continuation; ++j) {
            if (i == name.size()) return false;
            unsigned char next = name[i++];
            if ((next & 0xC0) != 0x80) return false;
            c = (c << 6) | (next & 63);
        }
        if (c < minimum || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF) || c < 32 || c == 127) return false;
        if (c < 128 && std::string("<>:\"/\\|?*").find(static_cast<char>(c)) != std::string::npos) return false;
    }
    std::string stem = name.substr(0, name.find('.'));
    while (!stem.empty() && stem.back() == ' ') stem.pop_back();
    for (auto& c : stem) if (c >= 'a' && c <= 'z') c -= 'a' - 'A';
    if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL") return false;
    if (stem.compare(0, 3, "COM") == 0 || stem.compare(0, 3, "LPT") == 0) {
        const auto suffix = stem.substr(3);
        if ((suffix.size() == 1 && suffix[0] >= '1' && suffix[0] <= '9') ||
            suffix == "\xc2\xb9" || suffix == "\xc2\xb2" || suffix == "\xc2\xb3") return false;
    }
    return true;
}
std::string nativeDigest(const std::string& bytes)
{
    unsigned char digest[SHA256_DIGEST_LENGTH];
    if (!SHA256(reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size(), digest))
        throw std::runtime_error("SHA-256 failed");
    return std::string(reinterpret_cast<char*>(digest), sizeof(digest));
}
std::shared_ptr<const NativeFile> readNativeFile(const std::string& path)
{
    auto p = fs::u8path(path);
    if (path.empty() || !fs::is_regular_file(fs::symlink_status(p)))
        throw std::runtime_error("Select one regular file (no folders or links)");
    auto file = std::make_shared<NativeFile>();
    file->name = p.filename().u8string();
    if (!nativeFilenameValid(file->name)) throw std::runtime_error("Filename is not supported on Windows");
    auto size = fs::file_size(p);
    if (size > nativeFileLimit) throw std::runtime_error("Native drop preview supports files up to 16 MiB");
    std::ifstream in;
    open_utf8_path(in, p, std::ios::binary);
    file->bytes.resize(static_cast<std::size_t>(size));
    if ((size && !in.read(&file->bytes[0], static_cast<std::streamsize>(size))) || in.peek() != EOF)
        throw std::runtime_error("Cannot read file, or file changed while reading");
    return file;
}
std::string encodeClipboardFile(const NativeFile& file)
{
    if (!nativeFilenameValid(file.name) || file.bytes.size() > nativeFileLimit)
        throw std::runtime_error("Clipboard supports one regular file up to 16 MiB");
    std::string data("NFC1");
    for (uint32_t value : {static_cast<uint32_t>(file.name.size()), static_cast<uint32_t>(file.bytes.size())})
        for (int shift = 24; shift >= 0; shift -= 8) data += static_cast<char>(value >> shift);
    return data + nativeDigest(file.bytes) + file.name + file.bytes;
}
std::shared_ptr<const NativeFile> decodeClipboardFile(const std::string& data)
{
    if (data.size() < 44 || data.compare(0, 4, "NFC1") != 0)
        throw std::runtime_error("Invalid clipboard file header");
    uint32_t nameSize = 0, size = 0;
    for (unsigned i = 4; i < 8; ++i) nameSize = (nameSize << 8) | static_cast<unsigned char>(data[i]);
    for (unsigned i = 8; i < 12; ++i) size = (size << 8) | static_cast<unsigned char>(data[i]);
    if (!nameSize || nameSize > 240 || size > nativeFileLimit || data.size() != 44 + nameSize + size)
        throw std::runtime_error("Invalid clipboard file size");
    auto file = std::make_shared<NativeFile>();
    file->name = data.substr(44, nameSize);
    file->bytes = data.substr(44 + nameSize);
    if (!nativeFilenameValid(file->name) || nativeDigest(file->bytes) != data.substr(12, 32))
        throw std::runtime_error("Invalid clipboard file name or digest");
    return file;
}
void NativeFileReceiver::reset() { file_.reset(); digest_.clear(); id_ = size_ = 0; }
void NativeFileReceiver::begin(uint32_t id, uint32_t size, const std::string& name, const std::string& digest)
{
    if (file_ || size > nativeFileLimit || !nativeFilenameValid(name) || digest.size() != SHA256_DIGEST_LENGTH) {
        reset(); throw std::runtime_error("Invalid native file offer");
    }
    file_ = std::make_shared<NativeFile>(); file_->name = name;
    id_ = id; size_ = size; digest_ = digest;
}
void NativeFileReceiver::append(uint32_t id, const std::string& bytes)
{
    if (!file_ || id != id_ || bytes.empty() || bytes.size() > nativeChunkLimit || bytes.size() > size_ - file_->bytes.size()) {
        reset(); throw std::runtime_error("Invalid native file chunk");
    }
    file_->bytes.append(bytes);
}
std::shared_ptr<const NativeFile> NativeFileReceiver::finish(uint32_t id)
{
    if (!file_ || id != id_ || file_->bytes.size() != size_ || nativeDigest(file_->bytes) != digest_) {
        reset(); throw std::runtime_error("Native file is incomplete or checksum differs");
    }
    auto result = file_; reset(); return result;
}
}
