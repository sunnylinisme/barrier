// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <string>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

namespace barrier {
constexpr ULONG_PTR nativeDragInputTag = 0x424e4452;
std::string captureWindowsNativeDrag();
bool cancelWindowsNativeDrag();
}
