// SPDX-License-Identifier: GPL-2.0-or-later
#include "NativeFileProtocol.h"
#include "ProtocolUtil.h"
#include <cstring>
#include <stdexcept>

namespace barrier {
void sendNativeFile(IStream* stream, uint32_t id, const NativeFile& file)
{
    if (file.bytes.size() > nativeFileLimit || !nativeFilenameValid(file.name))
        throw std::runtime_error("Invalid native file");
    auto digest = nativeDigest(file.bytes);
    ProtocolUtil::writef(stream, nativeBegin, id, static_cast<UInt32>(file.bytes.size()), &file.name, &digest);
    for (std::size_t offset = 0; offset < file.bytes.size(); offset += nativeChunkLimit) {
        auto chunk = file.bytes.substr(offset, nativeChunkLimit);
        ProtocolUtil::writef(stream, nativeChunk, id, &chunk);
    }
    ProtocolUtil::writef(stream, nativeEnd, id);
}
std::shared_ptr<const NativeFile> receiveNativeFile(IStream* stream, const unsigned char* code,
                                                  uint32_t expectedID, NativeFileReceiver& receiver)
{
    try {
        UInt32 id = 0;
        bool parsed = false;
        if (memcmp(code, nativeBegin, 4) == 0) {
            UInt32 size = 0; std::string name, digest;
            parsed = ProtocolUtil::readf(stream, nativeBegin + 4, &id, &size, &name, &digest);
            if (!parsed || id != expectedID) throw std::runtime_error("Invalid native file header");
            receiver.begin(id, size, name, digest);
        } else if (memcmp(code, nativeChunk, 4) == 0) {
            std::string bytes;
            parsed = ProtocolUtil::readf(stream, nativeChunk + 4, &id, &bytes);
            if (!parsed || id != expectedID) throw std::runtime_error("Invalid native file chunk header");
            receiver.append(id, bytes);
        } else if (memcmp(code, nativeEnd, 4) == 0) {
            parsed = ProtocolUtil::readf(stream, nativeEnd + 4, &id);
            if (!parsed || id != expectedID) throw std::runtime_error("Invalid native file completion");
            return receiver.finish(id);
        } else throw std::runtime_error("Unknown native file message");
        return {};
    } catch (...) { receiver.reset(); throw; }
}
}
