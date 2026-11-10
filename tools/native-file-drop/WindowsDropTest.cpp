// SPDX-License-Identifier: GPL-2.0-or-later
#include "platform/MSWindowsNativeDrag.h"
#include "platform/MSWindowsNativeFileOffer.h"
#include "arch/Arch.h"
#include "arch/win32/ArchMiscWindows.h"
#include "base/Log.h"
#include <iostream>
#include <stdexcept>
#include <cstring>
#include <shellapi.h>

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
// Exercise the filesystem Shell drop target, not just our permissive test target.
static bool shellFolderDrop(HWND window, std::shared_ptr<const barrier::NativeFile> file)
{
    wchar_t temp[MAX_PATH], folder[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, temp) || !GetTempFileNameW(temp, L"bnd", 0, folder)) return false;
    DeleteFileW(folder);
    if (!CreateDirectoryW(folder, nullptr)) return false;
    const std::wstring output = std::wstring(folder) + L"\\跨機測試.txt";
    IShellItem* item = nullptr;
    IDropTarget* target = nullptr;
    HRESULT result = SHCreateItemFromParsingName(folder, nullptr, IID_PPV_ARGS(&item));
    if (SUCCEEDED(result)) result = item->BindToHandler(nullptr, BHID_SFUIObject, IID_PPV_ARGS(&target));
    if (item) item->Release();
    bool passed = false;
    bool registered = false;
    if (SUCCEEDED(result)) {
        result = RegisterDragDrop(window, target);
        registered = SUCCEEDED(result);
    }
    std::cout << "test: filesystem Shell target HRESULT=" << std::hex << result << std::dec << "\n";
    if (registered) {
        SetForegroundWindow(window); SetCursorPos(200, 200); pump(100);
        MSWindowsNativeDrag drag;
        drag.start(file); pump(700); drag.release();
        auto deadline = GetTickCount64() + 8000;
        while (drag.active() && GetTickCount64() < deadline) pump(50);
        if (drag.active()) { std::cerr << "FAIL: Shell drag did not finish\n"; ExitProcess(1); }
        deadline = GetTickCount64() + 3000;
        do {
            HANDLE stream = CreateFileW(output.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
            if (stream != INVALID_HANDLE_VALUE) {
                char bytes[128]; DWORD count = 0;
                passed = ReadFile(stream, bytes, sizeof(bytes), &count, nullptr) && std::string(bytes, count) == payload;
                CloseHandle(stream);
                if (passed) break;
            }
            pump(50);
        } while (GetTickCount64() < deadline);
        RevokeDragDrop(window);
    }
    if (target) target->Release();
    DeleteFileW(output.c_str()); RemoveDirectoryW(folder);
    std::cout << (passed ? "PASS" : "FAIL") << ": actual filesystem Shell drop creates matching file\n";
    return passed;
}
struct ExplorerSearch { const wchar_t* title; HWND window = nullptr; };
static BOOL CALLBACK findExplorer(HWND window, LPARAM value) {
    auto search = reinterpret_cast<ExplorerSearch*>(value);
    wchar_t name[256], title[MAX_PATH];
    GetClassNameW(window, name, 256); GetWindowTextW(window, title, MAX_PATH);
    if (wcscmp(name, L"CabinetWClass") == 0 && wcscmp(title, search->title) == 0) search->window = window;
    return TRUE;
}
static DWORD integrity(DWORD pid) {
    DWORD level = 0, needed = 0;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid), token = nullptr;
    if (process && OpenProcessToken(process, TOKEN_QUERY, &token)) {
        GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &needed);
        std::vector<BYTE> data(needed);
        if (needed && GetTokenInformation(token, TokenIntegrityLevel, data.data(), needed, &needed)) {
            auto label = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(data.data());
            level = *GetSidSubAuthority(label->Label.Sid, *GetSidSubAuthorityCount(label->Label.Sid) - 1);
        }
        CloseHandle(token);
    }
    if (process) CloseHandle(process);
    return level;
}
static bool explorerDrop(std::shared_ptr<const barrier::NativeFile> file, bool localButton = false) {
    wchar_t temp[MAX_PATH], folder[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, temp) || !GetTempFileNameW(temp, L"bex", 0, folder)) return false;
    DeleteFileW(folder);
    if (!CreateDirectoryW(folder, nullptr)) return false;
    auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", folder, nullptr, nullptr, SW_SHOWNORMAL));
    ExplorerSearch search{PathFindFileNameW(folder)};
    auto deadline = GetTickCount64() + 15000;
    while (opened > 32 && !search.window && GetTickCount64() < deadline) {
        EnumWindows(findExplorer, reinterpret_cast<LPARAM>(&search)); pump(100);
    }
    bool passed = false;
    const std::wstring output = std::wstring(folder) + L"\\跨機測試.txt";
    if (search.window) {
        DWORD pid = 0; GetWindowThreadProcessId(search.window, &pid);
        std::cout << "test: source integrity=" << integrity(GetCurrentProcessId()) << " Explorer integrity=" << integrity(pid) << " local button=" << localButton << "\n";
        ShowWindow(search.window, SW_RESTORE);
        SetWindowPos(search.window, HWND_TOPMOST, 20, 20, 900, 650, SWP_SHOWWINDOW);
        SetForegroundWindow(search.window); pump(1000);
        RECT area; GetClientRect(search.window, &area);
        POINT point{area.right * 2 / 3, area.bottom * 2 / 3}; ClientToScreen(search.window, &point);
        SetCursorPos(point.x, point.y); pump(200);
        if (localButton) { mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0); pump(50); }
        MSWindowsNativeDrag drag; drag.start(file); pump(1500);
        if (localButton) mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        drag.release();
        deadline = GetTickCount64() + 8000;
        while (drag.active() && GetTickCount64() < deadline) pump(50);
        if (drag.active()) { std::cerr << "FAIL: Explorer drag did not finish\n"; ExitProcess(1); }
        deadline = GetTickCount64() + 5000;
        do {
            HANDLE stream = CreateFileW(output.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
            if (stream != INVALID_HANDLE_VALUE) {
                char bytes[128]; DWORD count = 0;
                passed = ReadFile(stream, bytes, sizeof(bytes), &count, nullptr) && std::string(bytes, count) == payload;
                CloseHandle(stream);
                if (passed) break;
            }
            pump(50);
        } while (GetTickCount64() < deadline);
        PostMessageW(search.window, WM_CLOSE, 0, 0); pump(300);
    } else std::cerr << "FAIL: Explorer window not found, ShellExecute=" << opened << "\n";
    DeleteFileW(output.c_str()); RemoveDirectoryW(folder);
    std::cout << (passed ? "PASS" : "FAIL") << ": real Explorer window creates matching file\n";
    return passed;
}
int main(int argc, char** argv)
{
    ArchMiscWindows::setInstanceWin32(GetModuleHandle(nullptr));
    std::cout << std::unitbuf;
    Arch arch; arch.init(); Log log; log.setFilter(kDEBUG2);
    std::cout << "test: initialized architecture\n";
    if (FAILED(OleInitialize(nullptr))) return 1;
    if (argc > 1 && std::strcmp(argv[1], "--explorer") == 0) {
        auto file = std::make_shared<barrier::NativeFile>(); file->name = "跨機測試.txt"; file->bytes = payload;
        bool passed = explorerDrop(file);
        if (!passed) { std::cout << "test: repeat with local left-button state as a diagnostic control\n"; explorerDrop(file, true); }
        OleUninitialize(); return passed ? 0 : 1;
    }
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
    RevokeDragDrop(window); target->Release();
    if (argc == 1) passed = shellFolderDrop(window, file) && passed;
    DestroyWindow(window); OleUninitialize();
    std::cout << (passed ? "PASS" : "FAIL") << ": actual OLE drag/drop using remote release and cancel\n";
    return passed ? 0 : 1;
}
