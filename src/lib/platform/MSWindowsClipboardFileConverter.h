// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "MSWindowsClipboard.h"

class MSWindowsClipboardFileConverter : public IMSWindowsClipboardConverter {
public:
    IClipboard::EFormat getFormat() const override { return IClipboard::kFile; }
    UINT getWin32Format() const override { return CF_HDROP; }
    HANDLE fromIClipboard(const std::string& data) const override;
    std::string toIClipboard(HANDLE data) const override;
};
