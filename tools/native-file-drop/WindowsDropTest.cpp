// SPDX-License-Identifier: GPL-2.0-or-later
#include "platform/MSWindowsNativeDrag.h"
#include "platform/MSWindowsNativeFileOffer.h"
#include "arch/Arch.h"
#include "arch/win32/ArchMiscWindows.h"
#include "base/Log.h"
#include <iostream>
#include <stdexcept>

static bool received = false;
static const std::string payload("network snapshot\n\x00\x01\xff", 20);
class Target final : public IDropTarget {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IDropTarget) return E_NOINTERFACE;
        *out = static_cast<IDropTarget*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override { LONG refs = InterlockedDecrement(&refs_); if (!refs) delete this; return refs; }
    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject*, DWORD, POINTL, DWORD* effect) override { *effect = DROPEFFECT_COPY; return S_OK; }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override { *effect = DROPEFFECT_COPY; return S_OK; }
    HRESULT STDMETHODCALLTYPE DragLeave() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Drop(IDataObject* offer, DWORD, POINTL, DWORD* effect) override {
        FORMATETC format = {static_cast<CLIPFORMAT>(RegisterClipboardFormat(CFSTR_FILECONTENTS)), nullptr, DVASPECT_CONTENT, 0, TYMED_ISTREAM};
        STGMEDIUM data = {};
        *effect = DROPEFFECT_NONE;
        if (FAILED(offer->GetData(&format, &data))) return E_FAIL;
        char buffer[128]; ULONG count = 0;
        HRESULT result = data.pstm->Read(buffer, sizeof(buffer), &count);
        received = SUCCEEDED(result) && std::string(buffer, count) == payload;
        ReleaseStgMedium(&data);
        if (received) *effect = DROPEFFECT_COPY;
        return S_OK;
    }
private: LONG refs_ = 1;
};
static void pump(unsigned milliseconds) {
    auto until = GetTickCount64() + milliseconds;
    do {
        MSG message;
        while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessage(&message); }
        Sleep(5);
    } while (GetTickCount64() < until);
}
int main(int argc, char**)
{
    ArchMiscWindows::setInstanceWin32(GetModuleHandle(nullptr));
    std::cout << std::unitbuf;
    Arch arch; arch.init(); Log log; log.setFilter(kDEBUG2);
    std::cout << "test: initialized architecture\n";
    if (FAILED(OleInitialize(nullptr))) return 1;
    WNDCLASSW wc = {}; wc.hInstance = GetModuleHandle(nullptr); wc.lpfnWndProc = DefWindowProcW; wc.lpszClassName = L"BarrierDropContract";
    RegisterClassW(&wc);
    HWND window = CreateWindowW(wc.lpszClassName, L"Native drop integration test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                30, 30, 640, 480, nullptr, nullptr, wc.hInstance, nullptr);
    Target* target = new Target;
    if (!window || FAILED(RegisterDragDrop(window, target))) return 1;
    std::cout << "test: native drop target registered\n";
    auto file = std::make_shared<barrier::NativeFile>(); file->name = "跨機測試.txt"; file->bytes = payload;
    bool passed = true;
    if (argc > 1) {
        SetForegroundWindow(window);
        auto deadline = GetTickCount64() + 20000;
        while (!received && GetTickCount64() < deadline) pump(50);
        passed = received;
    } else for (bool cancel : {false, true}) {
        received = false;
        SetForegroundWindow(window); SetCursorPos(200, 200); pump(100);
        {
            MSWindowsNativeDrag drag;
            drag.start(file); pump(700);
            if (cancel) drag.cancel(); else drag.release();
            auto deadline = GetTickCount64() + 8000;
            while (drag.active() && GetTickCount64() < deadline) pump(50);
            if (drag.active()) { std::cerr << "FAIL: OLE did not end after release/cancel\n"; ExitProcess(1); }
        }
        if (received == cancel) passed = false;
    }
    RevokeDragDrop(window); target->Release(); DestroyWindow(window); OleUninitialize();
    std::cout << (passed ? "PASS" : "FAIL") << ": actual OLE drag/drop using remote release and cancel\n";
    return passed ? 0 : 1;
}
