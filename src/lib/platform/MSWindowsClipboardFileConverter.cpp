// SPDX-License-Identifier: GPL-2.0-or-later
#include "MSWindowsClipboardFileConverter.h"
#include "barrier/NativeFileTransfer.h"
#include "common/DataDirectories.h"
#include "base/Log.h"
#include <shellapi.h>
#include <shlobj.h>
#include <objbase.h>
#include <fstream>
#include <cstring>
#include <stdexcept>
#include <vector>

std::string MSWindowsClipboardFileConverter::toIClipboard(HANDLE data) const
{
    try {
        HDROP drop = static_cast<HDROP>(data);
        if (DragQueryFileW(drop, 0xffffffff, nullptr, 0) != 1)
            throw std::runtime_error("Select one file for clipboard transfer");
        UINT length = DragQueryFileW(drop, 0, nullptr, 0);
        if (!length || length >= 32768) throw std::runtime_error("Invalid source path");
        std::vector<wchar_t> path(length + 1);
        if (DragQueryFileW(drop, 0, path.data(), length + 1) != length)
            throw std::runtime_error("Cannot read source path");
        auto file = barrier::readNativeFile(barrier::fs::path(path.data()).u8string());
        LOG((CLOG_INFO "file clipboard: captured %u bytes", static_cast<unsigned>(file->bytes.size())));
        return barrier::encodeClipboardFile(*file);
    } catch (const std::exception& e) {
        LOG((CLOG_WARN "file clipboard: %s", e.what())); return {};
    }
}

HANDLE MSWindowsClipboardFileConverter::fromIClipboard(const std::string& data) const
{
    barrier::fs::path directory;
    bool created = false;
    HGLOBAL memory = nullptr;
    try {
        auto file = barrier::decodeClipboardFile(data);
        GUID guid; wchar_t unique[40] = {};
        if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, unique, 40))
            throw std::runtime_error("Cannot allocate clipboard cache name");
        const auto cache = barrier::DataDirectories::profile() / "ClipboardCache";
        barrier::fs::create_directories(cache);
        directory = cache / unique;
        if (!barrier::fs::create_directory(directory)) throw std::runtime_error("Clipboard cache already exists");
        created = true;
        auto path = directory / barrier::fs::u8path(file->name);
        std::ofstream output;
        barrier::open_utf8_path(output, path, std::ios::binary);
        output.write(file->bytes.data(), file->bytes.size()); output.close();
        if (!output) throw std::runtime_error("Cannot write clipboard cache");
        // Keep the snapshot after process exit so Explorer can still paste it.
        auto wide = path.wstring();
        const auto size = sizeof(DROPFILES) + (wide.size() + 2) * sizeof(wchar_t);
        memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size);
        auto header = static_cast<DROPFILES*>(memory ? GlobalLock(memory) : nullptr);
        if (!header) throw std::runtime_error("Cannot allocate clipboard file list");
        header->pFiles = sizeof(DROPFILES); header->fWide = TRUE;
        memcpy(reinterpret_cast<char*>(header) + sizeof(DROPFILES), wide.data(), wide.size() * sizeof(wchar_t));
        GlobalUnlock(memory);
        LOG((CLOG_INFO "file clipboard: received and verified %u bytes; ready to paste", static_cast<unsigned>(file->bytes.size())));
        return memory;
    } catch (const std::exception& e) {
        if (memory) GlobalFree(memory);
        if (created) { std::error_code ignored; barrier::fs::remove_all(directory, ignored); }
        LOG((CLOG_WARN "file clipboard: %s", e.what())); return nullptr;
    }
}
