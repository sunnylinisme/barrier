// SPDX-License-Identifier: GPL-2.0-or-later
#include <windows.h>
#include <windowsx.h>
#include <ole2.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include "Sample.h"

#include "platform/MSWindowsNativeFileOffer.h"
static FileOffer* sampleOffer()
{
    auto file = std::make_shared<barrier::NativeFile>();
    file->name = sampleName(); file->bytes = sampleContent();
    return new FileOffer(file);
}

class DragSource final : public IDropSource {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override
    {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IDropSource) return E_NOINTERFACE;
        *out = static_cast<IDropSource*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override
    {
        LONG refs = InterlockedDecrement(&refs_);
        if (!refs) delete this;
        return static_cast<ULONG>(refs);
    }
    HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override
    {
        if (escape || (keys & MK_RBUTTON)) return DRAGDROP_S_CANCEL;
        return (keys & MK_LBUTTON) ? S_OK : DRAGDROP_S_DROP;
    }
    HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override { return DRAGDROP_S_USEDEFAULTCURSORS; }
private:
    LONG refs_ = 1;
};

static int selfTest()
{
    FileOffer* offer = sampleOffer();
    IEnumFORMATETC* enumerator = nullptr;
    bool passed = SUCCEEDED(offer->EnumFormatEtc(DATADIR_GET, &enumerator));
    FORMATETC formats[3] = {};
    ULONG count = 0;
    passed = passed && enumerator->Next(3, formats, &count) == S_OK && count == 3;
    std::printf("enumeration: ok=%d count=%lu indices=%ld,%ld\n", passed, count,
                formats[0].lindex, formats[1].lindex);
    if (enumerator) enumerator->Release();
    STGMEDIUM preference = {};
    passed = passed && SUCCEEDED(offer->GetData(&formats[2], &preference));
    if (preference.tymed == TYMED_HGLOBAL) {
        auto effect = static_cast<DWORD*>(GlobalLock(preference.hGlobal));
        passed = passed && effect && *effect == DROPEFFECT_COPY;
        if (effect) GlobalUnlock(preference.hGlobal);
        ReleaseStgMedium(&preference);
    } else passed = false;
    STGMEDIUM descriptor = {};
    passed = passed && SUCCEEDED(offer->GetData(&formats[0], &descriptor));
    if (descriptor.tymed == TYMED_HGLOBAL) {
        auto group = static_cast<FILEGROUPDESCRIPTORW*>(GlobalLock(descriptor.hGlobal));
        passed = passed && group && group->cItems == 1 &&
            wcscmp(group->fgd[0].cFileName, L"Barrier-拖放測試.txt") == 0 &&
            group->fgd[0].nFileSizeLow == sampleContent().size();
        if (group) GlobalUnlock(descriptor.hGlobal);
        ReleaseStgMedium(&descriptor);
    }
    std::printf("descriptor: ok=%d requests=%u\n", passed, offer->contentRequests);
    passed = passed && offer->contentRequests == 0;
    for (int i = 0; i < 2; ++i) {
        STGMEDIUM data = {};
        if (FAILED(offer->GetData(&formats[1], &data))) { passed = false; continue; }
        std::vector<char> bytes(sampleContent().size() + 1);
        ULONG read = 0;
        HRESULT result = data.pstm->Read(bytes.data(), static_cast<ULONG>(bytes.size()), &read);
        std::printf("stream %d: hr=%lx read=%lu expected=%zu equal=%d\n", i,
                    static_cast<unsigned long>(result), read, sampleContent().size(),
                    std::string(bytes.data(), read) == sampleContent());
        // SHCreateMemStream can return S_OK for a successful short read.
        // Check the bytes and a subsequent EOF read, not only the HRESULT.
        passed = passed && SUCCEEDED(result) && read == sampleContent().size() &&
            std::string(bytes.data(), read) == sampleContent();
        ULONG eofRead = 1;
        HRESULT eofResult = data.pstm->Read(bytes.data(), 1, &eofRead);
        passed = passed && SUCCEEDED(eofResult) && eofRead == 0;
        ReleaseStgMedium(&data);
    }
    FORMATETC bad = formats[1];
    bad.lindex = 1;
    STGMEDIUM invalid = {};
    passed = passed && offer->GetData(&bad, &invalid) == DV_E_LINDEX &&
        invalid.tymed == TYMED_NULL && offer->contentRequests == 2;
    bad = formats[1];
    bad.tymed = TYMED_HGLOBAL;
    passed = passed && offer->QueryGetData(&bad) == DV_E_TYMED;
    bad = formats[1];
    bad.dwAspect = DVASPECT_ICON;
    passed = passed && offer->QueryGetData(&bad) == DV_E_DVASPECT;
    passed = passed && offer->GetData(nullptr, &invalid) == E_POINTER;
    std::printf("data contract: ok=%d requests=%u\n", passed, offer->contentRequests);
    offer->Release();
    DragSource* source = new DragSource;
    passed = passed && source->QueryContinueDrag(TRUE, MK_LBUTTON) == DRAGDROP_S_CANCEL &&
        source->QueryContinueDrag(FALSE, MK_LBUTTON) == S_OK &&
        source->QueryContinueDrag(FALSE, 0) == DRAGDROP_S_DROP;
    source->Release();
    std::puts(passed ? "PASS: descriptors, UTF-8, deferred bytes, independent streams, invalid requests, cancel"
                     : "FAIL: native virtual file contract");
    return passed ? 0 : 1;
}

static const wchar_t* status = L"Drag the file below into a File Explorer folder.";
static const RECT tile = {24, 88, 496, 164};
static LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wp, LPARAM lp)
{
    switch (message) {
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        HFONT old = static_cast<HFONT>(SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT)));
        SetBkMode(dc, TRANSPARENT);
        RECT heading = {24, 22, 496, 52};
        DrawTextW(dc, L"Barrier — native drop preview", -1, &heading, DT_LEFT);
        RECT detail = {24, 54, 496, 80};
        DrawTextW(dc, L"Local receiver test — no network connection yet", -1, &detail, DT_LEFT);
        FillRect(dc, &tile, GetSysColorBrush(COLOR_WINDOW));
        RECT label = {40, 116, 480, 150};
        DrawTextW(dc, L"Barrier-拖放測試.txt", -1, &label, DT_LEFT);
        RECT result = {24, 188, 496, 244};
        DrawTextW(dc, status, -1, &result, DT_LEFT | DT_WORDBREAK);
        SelectObject(dc, old);
        EndPaint(window, &paint);
        return 0;
    }
    case WM_LBUTTONDOWN: {
        POINT point = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        if (!PtInRect(&tile, point)) return 0;
        FileOffer* offer = sampleOffer();
        DragSource* source = new DragSource;
        DWORD effect = DROPEFFECT_NONE;
        HRESULT result = DoDragDrop(offer, source, DROPEFFECT_COPY, &effect);
        status = result == DRAGDROP_S_DROP && (effect & DROPEFFECT_COPY)
            ? L"Copy accepted. Check the file in the destination folder."
            : L"Drag cancelled or rejected. No successful copy was reported.";
        source->Release();
        offer->Release();
        InvalidateRect(window, nullptr, TRUE);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wp, lp);
}

int main(int argc, char* argv[])
{
    HRESULT result = OleInitialize(nullptr);
    if (FAILED(result)) return 1;
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
        int code = selfTest();
        OleUninitialize();
        return code;
    }
    WNDCLASSW klass = {};
    klass.lpfnWndProc = windowProc;
    klass.hInstance = GetModuleHandleW(nullptr);
    klass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    klass.hbrBackground = GetSysColorBrush(COLOR_BTNFACE);
    klass.lpszClassName = L"BarrierNativeDropProbe";
    if (!RegisterClassW(&klass)) { OleUninitialize(); return 1; }
    HWND window = CreateWindowW(klass.lpszClassName, L"Barrier Drop Probe — development preview",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 540, 310, nullptr, nullptr, klass.hInstance, nullptr);
    if (!window) { OleUninitialize(); return 1; }
    ShowWindow(window, SW_SHOW);
    MSG message;
    int state;
    while ((state = static_cast<int>(GetMessageW(&message, nullptr, 0, 0))) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    OleUninitialize();
    return state == -1 ? 1 : static_cast<int>(message.wParam);
}
