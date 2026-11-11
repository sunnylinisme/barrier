// SPDX-License-Identifier: GPL-2.0-or-later
#include "platform/MSWindowsNativeDrag.h"
#include "platform/MSWindowsNativeSource.h"
#include "platform/MSWindowsNativeFileOffer.h"
#include "arch/Arch.h"
#include "arch/win32/ArchMiscWindows.h"
#include "base/Log.h"
#include <iostream>
#include <stdexcept>
#include <cstring>
#include <shellapi.h>
#include <vector>
#include <algorithm>
#include <UIAutomation.h>
#include "io/filesystem.h"
#include "platform/MSWindowsClipboardFileConverter.h"
#include "common/DataDirectories.h"
#include "barrier/FileClipboardTransfer.h"
#include <fstream>

static std::string readBytes(const barrier::fs::path& path) {
    std::ifstream in; barrier::open_utf8_path(in, path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

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
static void saveScreen(const wchar_t* path) {
    int width = GetSystemMetrics(SM_CXSCREEN), height = GetSystemMetrics(SM_CYSCREEN);
    HDC screen = GetDC(nullptr), memory = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
    auto old = SelectObject(memory, bitmap);
    BitBlt(memory, 0, 0, width, height, screen, 0, 0, SRCCOPY);
    SelectObject(memory, old);
    BITMAPINFO info = {}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    std::vector<BYTE> pixels(width * height * 4);
    if (GetDIBits(memory, bitmap, 0, height, pixels.data(), &info, DIB_RGB_COLORS)) {
        BITMAPFILEHEADER header = {}; header.bfType = 0x4d42;
        header.bfOffBits = sizeof(header) + sizeof(info.bmiHeader);
        header.bfSize = header.bfOffBits + static_cast<DWORD>(pixels.size());
        HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
        if (file != INVALID_HANDLE_VALUE) {
            DWORD written;
            WriteFile(file, &header, sizeof(header), &written, nullptr);
            WriteFile(file, &info.bmiHeader, sizeof(info.bmiHeader), &written, nullptr);
            WriteFile(file, pixels.data(), static_cast<DWORD>(pixels.size()), &written, nullptr);
            CloseHandle(file);
        }
    }
    DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(nullptr, screen);
}
struct ExplorerSearch { const wchar_t* title; HWND window = nullptr; };
static BOOL CALLBACK findExplorer(HWND window, LPARAM value) {
    auto search = reinterpret_cast<ExplorerSearch*>(value);
    wchar_t name[256], title[MAX_PATH];
    GetClassNameW(window, name, 256); GetWindowTextW(window, title, MAX_PATH);
    if (wcscmp(name, L"CabinetWClass") == 0 && wcscmp(title, search->title) == 0) search->window = window;
    return TRUE;
}
static bool explorerDrop(std::shared_ptr<const barrier::NativeFile> file, bool movePointer) {
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
        ShowWindow(search.window, SW_RESTORE);
        SetWindowPos(search.window, HWND_TOPMOST, 20, 20, 900, 650, SWP_SHOWWINDOW);
        SetForegroundWindow(search.window); pump(1000);
        RECT area; GetClientRect(search.window, &area);
        POINT point{area.right * 2 / 3, area.bottom * 2 / 3}; ClientToScreen(search.window, &point);
        SetCursorPos(point.x, point.y); pump(200);
        MSWindowsNativeDrag drag; drag.start(file); pump(300);
        if (movePointer) mouse_event(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE,
                    static_cast<DWORD>((point.x + 15) * 65535.0 / (GetSystemMetrics(SM_CXSCREEN) - 1)),
                    static_cast<DWORD>((point.y + 15) * 65535.0 / (GetSystemMetrics(SM_CYSCREEN) - 1)), 0, 0);
        pump(1200);
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
        if (!passed) saveScreen(movePointer ? L"explorer-moving.bmp" : L"explorer-stationary.bmp");
        PostMessageW(search.window, WM_CLOSE, 0, 0); pump(300);
    } else std::cerr << "FAIL: Explorer window not found, ShellExecute=" << opened << "\n";
    DeleteFileW(output.c_str()); RemoveDirectoryW(folder);
    std::cout << (passed ? "PASS" : "FAIL") << ": real Explorer window creates matching file\n";
    return passed;
}
static std::string utf8(const wchar_t* text) {
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, nullptr, 0, nullptr, nullptr);
    std::vector<char> buffer(size);
    if (!size || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, buffer.data(), size, nullptr, nullptr)) return {};
    return buffer.data();
}
static void key(WORD code, bool up = false) {
    INPUT input = {}; input.type = INPUT_KEYBOARD; input.ki.wVk = code;
    input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0; SendInput(1, &input, sizeof(input));
}
static bool itemPoint(HWND window, POINT& point) {
    IUIAutomation* automation = nullptr;
    IUIAutomationElement* root = nullptr;
    if (FAILED(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation)))) return false;
    automation->ElementFromHandle(window, &root);
    bool found = false;
    if (root) for (const wchar_t* name : {L"跨機來源測試.txt", L"跨機來源測試"}) {
        VARIANT value; VariantInit(&value); value.vt = VT_BSTR; value.bstrVal = SysAllocString(name);
        IUIAutomationCondition* condition = nullptr;
        IUIAutomationElement* item = nullptr;
        if (SUCCEEDED(automation->CreatePropertyCondition(UIA_NamePropertyId, value, &condition))) {
            root->FindFirst(TreeScope_Descendants, condition, &item);
            if (item) {
                RECT area = {};
                if (SUCCEEDED(item->get_CurrentBoundingRectangle(&area)) && area.right > area.left && area.bottom > area.top) {
                    point.x = area.left + (std::min)(40L, (area.right - area.left) / 2);
                    point.y = (area.top + area.bottom) / 2; found = true;
                }
                item->Release();
            }
            condition->Release();
        }
        VariantClear(&value);
        if (found) break;
    }
    if (root) root->Release(); automation->Release(); return found;
}
static bool writeSource(const std::wstring& path, const std::string& bytes = payload) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD count = 0;
    bool ok = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr) && count == bytes.size();
    CloseHandle(file); return ok;
}
static bool clipboardExplorer(const wchar_t* folder, bool paste, const std::string& expected = payload) {
    const auto path = barrier::fs::path(folder) / barrier::fs::u8path("跨機複製測試.txt");
    if (!paste && !writeSource(path.wstring(), expected)) return false;
    auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", folder, nullptr, nullptr, SW_SHOWNORMAL));
    ExplorerSearch search{PathFindFileNameW(folder)};
    auto deadline = GetTickCount64() + 15000;
    while (opened > 32 && !search.window && GetTickCount64() < deadline) {
        EnumWindows(findExplorer, reinterpret_cast<LPARAM>(&search)); pump(100);
    }
    if (!search.window) return false;
    SetWindowPos(search.window, HWND_TOPMOST, 20, 20, 900, 650, SWP_SHOWWINDOW);
    SetForegroundWindow(search.window); pump(700);
    const auto serial = GetClipboardSequenceNumber();
    key(VK_CONTROL);
    if (!paste) { key('A'); key('A', true); }
    key(paste ? 'V' : 'C'); key(paste ? 'V' : 'C', true); key(VK_CONTROL, true);
    bool passed = false;
    deadline = GetTickCount64() + 8000;
    do {
        try {
            if (paste && barrier::fs::exists(path)) passed = readBytes(path) == expected;
            if (!paste && GetClipboardSequenceNumber() != serial && OpenClipboard(nullptr)) {
                auto handle = GetClipboardData(CF_HDROP);
                MSWindowsClipboardFileConverter converter;
                auto encoded = handle ? converter.toIClipboard(handle) : std::string();
                CloseClipboard();
                if (!encoded.empty()) {
                    auto files = barrier::clipboardFiles(encoded);
                    passed = files->roots.size() == 1 && readBytes(files->roots[0]) == expected;
                }
            }
        } catch (...) {}
        if (passed) break;
        pump(100);
    } while (GetTickCount64() < deadline);
    if (!passed) saveScreen(L"explorer-clipboard.bmp");
    PostMessageW(search.window, WM_CLOSE, 0, 0); pump(300);
    std::cout << (passed ? "PASS" : "FAIL") << ": actual Explorer " << (paste ? "paste" : "copy") << " and file bytes\n";
    return passed;
}
static bool clipboardRoundtrip() {
    wchar_t temp[MAX_PATH], folder[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, temp) || !GetTempFileNameW(temp, L"bcp", 0, folder)) return false;
    DeleteFileW(folder); if (!CreateDirectoryW(folder, nullptr)) return false;
    const auto root = barrier::fs::path(folder), destination = root / "destination";
    barrier::fs::create_directory(destination);
    barrier::DataDirectories::profile(root / "profile");
    HWND window = CreateWindowW(L"STATIC", L"Clipboard test", 0, 0, 0, 1, 1, HWND_MESSAGE, nullptr, GetModuleHandle(nullptr), nullptr);
    MSWindowsClipboard clipboard(window, true);
    const auto source = root / barrier::fs::u8path("跨機複製測試.txt");
    if (!writeSource(source.wstring())) return false;
    const auto sourceFolder = root / barrier::fs::u8path("資料夾");
    barrier::fs::create_directories(sourceFolder / "empty");
    if (!writeSource((sourceFolder / "nested.txt").wstring(), "nested content")) return false;
    auto wire = barrier::registerClipboardFiles({source, sourceFolder});
    bool passed = clipboard.open(0);
    if (passed) { passed = clipboard.empty(); clipboard.add(IClipboard::kFile, wire); clipboard.close(); }
    MSWindowsClipboardFileConverter converter;
    if (OpenClipboard(window)) {
        auto data = GetClipboardData(CF_HDROP);
        auto handle = data ? converter.toIClipboard(data) : std::string();
        CloseClipboard();
        passed = !handle.empty() && barrier::clipboardFiles(handle)->roots.size() == 2 && passed;
    } else passed = false;
    wire[12] ^= 1;
    passed = converter.fromIClipboard(wire) == nullptr && passed;
    passed = clipboardExplorer(destination.wstring().c_str(), true) && passed;
    auto deadline = GetTickCount64() + 8000;
    const auto copiedFolder = destination / sourceFolder.filename();
    while (!barrier::fs::exists(copiedFolder / "nested.txt") && GetTickCount64() < deadline) pump(100);
    passed = barrier::fs::is_directory(copiedFolder / "empty") && barrier::fs::exists(copiedFolder / "nested.txt") && readBytes(copiedFolder / "nested.txt") == "nested content" && passed;
    std::cout << (passed ? "PASS" : "FAIL") << ": multiple CF_HDROP items and actual Explorer folder/empty-directory paste\n";
    if (OpenClipboard(window)) { EmptyClipboard(); CloseClipboard(); }
    DestroyWindow(window); barrier::fs::remove_all(root);
    return passed;
}
static bool explorerSource(const wchar_t* folder, bool serverMode) {
    const std::wstring path = std::wstring(folder) + L"\\跨機來源測試.txt";
    const std::wstring second = std::wstring(folder) + L"\\second.txt";
    if (!writeSource(path)) return false;
    auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", folder, nullptr, nullptr, SW_SHOWNORMAL));
    ExplorerSearch search{PathFindFileNameW(folder)};
    auto deadline = GetTickCount64() + 15000;
    while (opened > 32 && !search.window && GetTickCount64() < deadline) {
        EnumWindows(findExplorer, reinterpret_cast<LPARAM>(&search)); pump(100);
    }
    bool passed = search.window != nullptr;
    if (search.window) {
        SetWindowPos(search.window, HWND_NOTOPMOST, 20, 20, 900, 650, SWP_SHOWWINDOW);
        SetForegroundWindow(search.window); pump(1000);
        for (bool multiple : {false, true}) {
            if (serverMode && multiple) break;
            if (multiple) { passed = writeSource(second) && passed; key(VK_F5); key(VK_F5, true); pump(500); }
            key(VK_CONTROL); key('A'); key('A', true); key(VK_CONTROL, true); pump(100);
            POINT point = {};
            if (!itemPoint(search.window, point)) { std::cerr << "FAIL: source item not found by UI Automation\n"; passed = false; break; }
            SetCursorPos(point.x, point.y); pump(100);
            mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0); pump(100);
            SetCursorPos(point.x + 40, point.y + 20); pump(300);
            if (serverMode) {
                // Ordinary input (no private tag) must travel through the real server hooks.
                mouse_event(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, 65535,
                            static_cast<DWORD>((point.y + 20) * 65535.0 / (GetSystemMetrics(SM_CYSCREEN) - 1)), 0, 0);
                pump(1000);
                // A tiny hand movement while waiting at the receiving edge must not cancel the file.
                mouse_event(MOUSEEVENTF_MOVE, static_cast<DWORD>(-2), 0, 0, 0);
                pump(1000);
                mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0); pump(300);
                // A deliberate movement back must still return control to the host.
                mouse_event(MOUSEEVENTF_MOVE, static_cast<DWORD>(-64), 0, 0, 0); pump(300);
            } else {
                GUITHREADINFO gui = {}; gui.cbSize = sizeof(gui);
                GetGUIThreadInfo(GetWindowThreadProcessId(GetForegroundWindow(), nullptr), &gui);
                char captureClass[128] = {}; GetClassNameA(gui.hwndCapture, captureClass, sizeof(captureClass));
                std::cout << "test: Explorer capture=" << captureClass << " left=" << GetAsyncKeyState(VK_LBUTTON) << "\n";
                if (!multiple) saveScreen(L"explorer-source-held.bmp");
                auto captured = barrier::captureWindowsNativeDrag();
                std::error_code error;
                bool correct = multiple ? captured.empty() : !captured.empty() &&
                    barrier::fs::equivalent(barrier::fs::u8path(captured), path, error) && !error;
                std::cout << (correct ? "PASS" : "FAIL") << ": Explorer source capture, multiple=" << multiple << "\n";
                passed = correct && passed;
                passed = barrier::cancelWindowsNativeDrag() && passed; pump(300);
            }
            try { passed = barrier::readNativeFile(utf8(path.c_str()))->bytes == payload && passed; }
            catch (...) { passed = false; }
        }
        if (!passed) saveScreen(L"explorer-source.bmp");
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        PostMessageW(search.window, WM_CLOSE, 0, 0); pump(300);
    }
    DeleteFileW(path.c_str()); DeleteFileW(second.c_str());
    std::cout << (passed ? "PASS" : "FAIL") << ": actual Explorer source drag preserves original bytes\n";
    return passed;
}
int main(int argc, char** argv)
{
    ArchMiscWindows::setInstanceWin32(GetModuleHandle(nullptr));
    std::cout << std::unitbuf;
    Arch arch; arch.init(); Log log; log.setFilter(kDEBUG2);
    std::cout << "test: initialized architecture\n";
    if (FAILED(OleInitialize(nullptr))) return 1;
    if (argc > 1 && std::strcmp(argv[1], "--clipboard-roundtrip") == 0) {
        bool passed = clipboardRoundtrip(); OleUninitialize(); return passed ? 0 : 1;
    }
    if ((argc == 3 || argc == 4) && (std::strcmp(argv[1], "--clipboard-copy") == 0 || std::strcmp(argv[1], "--clipboard-paste") == 0)) {
        auto expected = argc == 4 ? readBytes(barrier::fs::u8path(argv[3])) : payload;
        bool passed = clipboardExplorer(barrier::fs::u8path(argv[2]).wstring().c_str(), std::strcmp(argv[1], "--clipboard-paste") == 0, expected);
        OleUninitialize(); return passed ? 0 : 1;
    }
    if ((argc == 2 || argc == 3) && (std::strcmp(argv[1], "--clipboard-cross") == 0 || std::strcmp(argv[1], "--clipboard-return") == 0)) {
        std::string direction = argc == 3 ? argv[2] : "right";
        if (std::strcmp(argv[1], "--clipboard-cross") == 0) {
            DWORD x = direction == "right" ? 65535 : direction == "left" ? 0 : 30000;
            DWORD y = direction == "down" ? 65535 : direction == "up" ? 0 : 30000;
            mouse_event(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, x, y, 0, 0);
        } else {
            int dx = direction == "right" ? -64 : direction == "left" ? 64 : 0;
            int dy = direction == "down" ? -64 : direction == "up" ? 64 : 0;
            mouse_event(MOUSEEVENTF_MOVE, static_cast<DWORD>(dx), static_cast<DWORD>(dy), 0, 0);
        }
        pump(500); OleUninitialize(); return 0;
    }
    if (argc > 1 && std::strcmp(argv[1], "--explorer") == 0) {
        auto file = std::make_shared<barrier::NativeFile>(); file->name = "跨機測試.txt"; file->bytes = payload;
        bool passed = true;
        for (bool move : {false, true}) {
            std::cout << "test: Explorer remote drag, move pointer=" << move << "\n";
            passed = explorerDrop(file, move) && passed;
        }
        OleUninitialize(); return passed ? 0 : 1;
    }
    if (argc > 1 && (std::strcmp(argv[1], "--source") == 0 || std::strcmp(argv[1], "--server-source") == 0)) {
        wchar_t folder[MAX_PATH] = {}, temp[MAX_PATH];
        bool serverMode = std::strcmp(argv[1], "--server-source") == 0;
        if (serverMode) {
            if (argc != 3 || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, folder, MAX_PATH)) return 1;
        } else {
            if (!GetTempPathW(MAX_PATH, temp) || !GetTempFileNameW(temp, L"bws", 0, folder)) return 1;
            DeleteFileW(folder); if (!CreateDirectoryW(folder, nullptr)) return 1;
        }
        bool passed = explorerSource(folder, serverMode);
        if (!serverMode) RemoveDirectoryW(folder);
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
