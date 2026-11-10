// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <string>

// The same UTF-8 fixture is offered by both native implementations.
inline const char* sampleName() { return u8"Barrier-拖放測試.txt"; }
inline std::string sampleContent()
{
    return u8"Barrier native file drop preview\r\n"
           u8"UTF-8: 中文檔名與內容 / Windows / macOS\r\n"
           "This file was generated when the destination requested its contents.\r\n";
}
