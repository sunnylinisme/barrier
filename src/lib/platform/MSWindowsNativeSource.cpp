// SPDX-License-Identifier: GPL-2.0-or-later
#include "MSWindowsNativeSource.h"
#include <ole2.h>
#include <shellapi.h>
#include <thread>
#include <vector>
#include <algorithm>

namespace barrier {
namespace {
class CaptureTarget final : public IDropTarget {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IDropTarget) return E_NOINTERFACE;
        *out = static_cast<IDropTarget*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG refs = InterlockedDecrement(&refs_); if (!refs) delete this; return refs;
    }
    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD keys, POINTL, DWORD* effect) override {
        entered = true;
        *effect = DROPEFFECT_NONE; // Observe the offer; never perform a local copy or move.
        if (!(keys & MK_LBUTTON)) return S_OK;
        FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM medium = {};
        if (FAILED(data->GetData(&format, &medium))) return S_OK;
        if (medium.tymed == TYMED_HGLOBAL && medium.hGlobal &&
            DragQueryFileW(static_cast<HDROP>(medium.hGlobal), 0xffffffff, nullptr, 0) == 1) {
            UINT count = DragQueryFileW(static_cast<HDROP>(medium.hGlobal), 0, nullptr, 0);
            if (count && count < 32768) {
                std::vector<wchar_t> wide(count + 1);
                if (DragQueryFileW(static_cast<HDROP>(medium.hGlobal), 0, wide.data(), count + 1) == count) {
                    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), count, nullptr, 0, nullptr, nullptr);
                    if (bytes > 0) {
                        path.resize(bytes);
                        WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), count, &path[0], bytes, nullptr, nullptr);
                    }
                }
            }
        }
        ReleaseStgMedium(&medium);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override { *effect = DROPEFFECT_NONE; return S_OK; }
    HRESULT STDMETHODCALLTYPE DragLeave() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Drop(IDataObject*, DWORD, POINTL, DWORD* effect) override { *effect = DROPEFFECT_NONE; return S_OK; }
    bool entered = false;
    std::string path;
private:
    LONG refs_ = 1;
};
void nudgeDrag() {
    INPUT input = {}; input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_MOVE; input.mi.dwExtraInfo = nativeDragInputTag;
    SendInput(1, &input, sizeof(input));
}
}
std::string captureWindowsNativeDrag()
{
    if (!(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) return {};
    std::string result;
    // A separate STA pumps the Explorer data object's calls while Barrier waits at the boundary.
    std::thread worker([&result]() {
        if (FAILED(OleInitialize(nullptr))) return;
        POINT point; GetCursorPos(&point);
        WNDCLASSW wc = {}; wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpfnWndProc = DefWindowProcW; wc.lpszClassName = L"BarrierNativeSourceCapture";
        RegisterClassW(&wc);
        HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
            wc.lpszClassName, L"", WS_POPUP, point.x - 48, point.y - 48, 96, 96,
            nullptr, nullptr, wc.hInstance, nullptr);
        auto target = new CaptureTarget;
        bool registered = window && SUCCEEDED(RegisterDragDrop(window, target));
        if (registered) {
            // Alpha zero would make the window invisible to OLE hit testing as well.
            SetLayeredWindowAttributes(window, 0, 1, LWA_ALPHA);
            SetWindowPos(window, HWND_TOPMOST, point.x - 48, point.y - 48, 96, 96, SWP_NOACTIVATE | SWP_SHOWWINDOW);
            nudgeDrag();
            auto deadline = GetTickCount64() + 600;
            auto nextNudge = GetTickCount64() + 100;
            while (!target->entered && GetTickCount64() < deadline && (GetAsyncKeyState(VK_LBUTTON) & 0x8000)) {
                MSG msg;
                while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
                if (GetTickCount64() >= nextNudge) { nudgeDrag(); nextNudge += 100; }
                MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
            }
            if (GetAsyncKeyState(VK_LBUTTON) & 0x8000) result = target->path;
            ShowWindow(window, SW_HIDE);
            RevokeDragDrop(window);
        }
        target->Release();
        if (window) DestroyWindow(window);
        OleUninitialize();
    });
    worker.join();
    return result;
}
bool cancelWindowsNativeDrag()
{
    if (!(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) return false;
    INPUT input[3] = {};
    input[0].type = input[1].type = INPUT_KEYBOARD;
    input[0].ki.wVk = input[1].ki.wVk = VK_ESCAPE;
    input[0].ki.dwExtraInfo = input[1].ki.dwExtraInfo = nativeDragInputTag;
    input[1].ki.dwFlags = KEYEVENTF_KEYUP;
    input[2].type = INPUT_MOUSE; input[2].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    input[2].mi.dwExtraInfo = nativeDragInputTag;
    return SendInput(3, input, sizeof(INPUT)) == 3;
}
}
