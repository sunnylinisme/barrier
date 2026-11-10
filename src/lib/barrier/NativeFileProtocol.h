// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "NativeFileTransfer.h"
namespace barrier {
class IStream;
void sendNativeFile(IStream* stream, uint32_t id, const NativeFile& file);
std::shared_ptr<const NativeFile> receiveNativeFile(IStream* stream, const unsigned char* code,
                                                  uint32_t expectedID, NativeFileReceiver& receiver);
}
