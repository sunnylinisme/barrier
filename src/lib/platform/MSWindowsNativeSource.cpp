// SPDX-License-Identifier: GPL-2.0-or-later
#include "MSWindowsNativeSource.h"
#include "base/Log.h"
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
        HRESULT result = data->GetData(&format, &medium);
        LOG((CLOG_DEBUG "native source: DragEnter keys=%lu format result=%lx", keys, static_cast<unsigned long>(result)));
        if (FAILED(result)) return S_OK;
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
    POINT point; GetCursorPos(&point);
    LONG step = point.x > GetSystemMetrics(SM_XVIRTUALSCREEN) ? -1 : 1;
    INPUT input[2] = {};
    for (auto& event : input) {
        event.type = INPUT_MOUSE;
        event.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_MOVE_NOCOALESCE;
        event.mi.dwExtraInfo = nativeDragInputTag;
    }
    input[0].mi.dx = step; input[1].mi.dx = -step;
    SendInput(2, input, sizeof(INPUT));
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
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
        RegisterClassW(&wc);
        HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            wc.lpszClassName, L"", WS_POPUP, point.x - 8, point.y - 8, 16, 16,
            nullptr, nullptr, wc.hInstance, nullptr);
        auto target = new CaptureTarget;
        bool registered = window && SUCCEEDED(RegisterDragDrop(window, target));
        if (registered) {
            // Keep the brief observer opaque so Explorer can hit-test it reliably.
            SetWindowPos(window, HWND_TOPMOST, point.x - 8, point.y - 8, 16, 16, SWP_NOACTIVATE | SWP_SHOWWINDOW);
            UpdateWindow(window);
            char hit[128] = {}; GetClassNameA(WindowFromPoint(point), hit, sizeof(hit));
            LOG((CLOG_DEBUG "native source: observer visible=%d hit=%s", int(IsWindowVisible(window)), hit));
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
            LOG((CLOG_DEBUG "native source: capture entered=%d path bytes=%u", int(target->entered), static_cast<unsigned>(result.size())));
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
