// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <Carbon/Carbon.h>
#include <string>
bool osxClipboardHasFiles(PasteboardRef);
std::string osxClipboardGetFiles(PasteboardRef);
void osxClipboardPutFiles(PasteboardRef, const std::string&);
