// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <ole2.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <cstdio>
#include "barrier/NativeFileTransfer.h"

// Explorer chooses the destination. It requests index 0's bytes only when needed.
class FileOffer final : public IDataObject {
public:
    explicit FileOffer(std::shared_ptr<const barrier::NativeFile> file) : file_(std::move(file)), descriptor_(static_cast<CLIPFORMAT>(RegisterClipboardFormat(CFSTR_FILEDESCRIPTORW))),
                  contents_(static_cast<CLIPFORMAT>(RegisterClipboardFormat(CFSTR_FILECONTENTS))),
                  preferred_(static_cast<CLIPFORMAT>(RegisterClipboardFormat(CFSTR_PREFERREDDROPEFFECT))) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override
    {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IDataObject) return E_NOINTERFACE;
        *out = static_cast<IDataObject*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override
    {
        const LONG refs = InterlockedDecrement(&refs_);
        if (!refs) delete this;
        return static_cast<ULONG>(refs);
    }
    HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* format) override
    {
        if (!format) return E_POINTER;
        char name[128] = {}; GetClipboardFormatNameA(format->cfFormat, name, sizeof(name));
        std::fprintf(stderr, "native format: query %s (%u), index=%ld tymed=%lu\n", name, format->cfFormat, format->lindex, format->tymed);
        if (format->dwAspect != DVASPECT_CONTENT) return DV_E_DVASPECT;
        if (format->cfFormat == descriptor_ || format->cfFormat == preferred_) {
            if (format->lindex != -1) return DV_E_LINDEX;
            return (format->tymed & TYMED_HGLOBAL) ? S_OK : DV_E_TYMED;
        }
        if (format->cfFormat == contents_) {
            if (format->lindex != 0) return DV_E_LINDEX;
            return (format->tymed & TYMED_ISTREAM) ? S_OK : DV_E_TYMED;
        }
        return DV_E_FORMATETC;
    }
    HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format, STGMEDIUM* medium) override
    {
        if (!medium) return E_POINTER;
        ZeroMemory(medium, sizeof(*medium));
        HRESULT result = QueryGetData(format);
        if (FAILED(result)) return result;
        if (format->cfFormat == preferred_) {
            HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
            if (!handle) return E_OUTOFMEMORY;
            auto effect = static_cast<DWORD*>(GlobalLock(handle));
            if (!effect) { GlobalFree(handle); return E_OUTOFMEMORY; }
            *effect = DROPEFFECT_COPY;
            GlobalUnlock(handle);
            medium->tymed = TYMED_HGLOBAL; medium->hGlobal = handle;
            return S_OK;
        }
        if (format->cfFormat == descriptor_) {
            HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(FILEGROUPDESCRIPTORW));
            if (!handle) return E_OUTOFMEMORY;
            auto group = static_cast<FILEGROUPDESCRIPTORW*>(GlobalLock(handle));
            if (!group) { GlobalFree(handle); return E_OUTOFMEMORY; }
            group->cItems = 1;
            auto& file = group->fgd[0];
            file.dwFlags = static_cast<DWORD>(FD_ATTRIBUTES | FD_FILESIZE | FD_UNICODE);
            file.dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
            file.nFileSizeLow = static_cast<DWORD>(file_->bytes.size());
            if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, file_->name.c_str(), -1,
                                     file.cFileName, MAX_PATH)) {
                GlobalUnlock(handle);
                GlobalFree(handle);
                return E_FAIL;
            }
            GlobalUnlock(handle);
            medium->tymed = TYMED_HGLOBAL;
            medium->hGlobal = handle;
            return S_OK;
        }
        const std::string& content = file_->bytes;
        IStream* stream = SHCreateMemStream(reinterpret_cast<const BYTE*>(content.data()),
                                          static_cast<UINT>(content.size()));
        if (!stream) return E_OUTOFMEMORY;
        ++contentRequests;
        medium->tymed = TYMED_ISTREAM;
        medium->pstm = stream;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return DATA_E_FORMATETC; }
    HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC* out) override
    {
        if (!out) return E_POINTER;
        out->ptd = nullptr;
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE SetData(FORMATETC* format, STGMEDIUM* medium, BOOL release) override
    {
        if (!format || !medium) return E_POINTER;
        const UINT performed = RegisterClipboardFormat(CFSTR_PERFORMEDDROPEFFECT);
        const UINT pasted = RegisterClipboardFormat(CFSTR_PASTESUCCEEDED);
        if ((format->cfFormat != performed && format->cfFormat != pasted) ||
            format->dwAspect != DVASPECT_CONTENT || medium->tymed != TYMED_HGLOBAL ||
            !medium->hGlobal || GlobalSize(medium->hGlobal) < sizeof(DWORD)) return DV_E_FORMATETC;
        // Feedback only. This copy-only transfer never deletes a source file.
        if (release) ReleaseStgMedium(medium);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC** out) override
    {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (direction != DATADIR_GET) return E_NOTIMPL;
        FORMATETC formats[] = {{descriptor_, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL},
                               {contents_, nullptr, DVASPECT_CONTENT, 0, TYMED_ISTREAM},
                               {preferred_, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL}};
        return SHCreateStdEnumFmtEtc(3, formats, out);
    }
    HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override
        { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA** out) override
        { if (out) *out = nullptr; return OLE_E_ADVISENOTSUPPORTED; }
    unsigned contentRequests = 0;
private:
    std::shared_ptr<const barrier::NativeFile> file_;
    LONG refs_ = 1;
    CLIPFORMAT descriptor_;
    CLIPFORMAT contents_;
    CLIPFORMAT preferred_;
};

