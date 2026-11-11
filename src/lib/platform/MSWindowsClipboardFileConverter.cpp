// SPDX-License-Identifier: GPL-2.0-or-later
#include "MSWindowsClipboardFileConverter.h"
#include "barrier/FileClipboardTransfer.h"
#include "base/Log.h"
#include <shellapi.h>
#include <shlobj.h>
#include <cstring>
#include <stdexcept>
#include <vector>

std::string MSWindowsClipboardFileConverter::toIClipboard(HANDLE data) const
{
    try {
        HDROP drop = static_cast<HDROP>(data);
        UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
        if (!count || count > 4096) throw std::runtime_error("Select between 1 and 4096 files or folders");
        std::vector<barrier::fs::path> paths;
        for (UINT i = 0; i < count; ++i) {
            UINT length = DragQueryFileW(drop, i, nullptr, 0);
            if (!length || length >= 32768) throw std::runtime_error("Invalid source path");
            std::vector<wchar_t> path(length + 1);
            if (DragQueryFileW(drop, i, path.data(), length + 1) != length) throw std::runtime_error("Cannot read source path");
            paths.emplace_back(path.data());
        }
        auto handle = barrier::registerClipboardFiles(paths);
        LOG((CLOG_INFO "file clipboard: captured %u selected items", count));
        return handle;
    } catch (const std::exception& e) { LOG((CLOG_WARN "file clipboard: %s", e.what())); return {}; }
}

HANDLE MSWindowsClipboardFileConverter::fromIClipboard(const std::string& data) const
{
    HGLOBAL memory = nullptr;
    try {
        auto files = barrier::clipboardFiles(data);
        std::wstring list;
        for (const auto& path : files->roots) { list += path.wstring(); list += L'\0'; }
        list += L'\0';
        memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + list.size() * sizeof(wchar_t));
        auto header = static_cast<DROPFILES*>(memory ? GlobalLock(memory) : nullptr);
        if (!header) throw std::runtime_error("Cannot allocate clipboard file list");
        header->pFiles = sizeof(DROPFILES); header->fWide = TRUE;
        memcpy(reinterpret_cast<char*>(header) + sizeof(DROPFILES), list.data(), list.size() * sizeof(wchar_t));
        GlobalUnlock(memory);
        return memory;
    } catch (const std::exception& e) {
        if (memory) GlobalFree(memory);
        LOG((CLOG_WARN "file clipboard: %s", e.what())); return nullptr;
    }
}
