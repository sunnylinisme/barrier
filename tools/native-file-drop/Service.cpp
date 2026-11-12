// SPDX-License-Identifier: GPL-2.0-or-later
// Barrier Share service (Windows). Runs the keyboard/mouse core with the session's
// winlogon token so it keeps working on the sign-in screen, the lock screen and UAC
// prompts, which a normal user process cannot reach.
//
// Security model:
// - Only the user of the active console session may control it, over a local-only pipe.
// - The service never opens paths the user chose: the GUI sends the pairing identity,
//   trusted fingerprints and screen config as data, and the service writes them under
//   <install dir>\state\<user SID>\, which only SYSTEM and Administrators can modify
//   (the user may read it, so the log and received files are reachable).
// - Executables come from the service's own directory; the address must be IPv4.
// - The last command is kept, so after sign-out the core is started again in the new
//   console session and the sign-in screen can be controlled from the other computer.
//
// Pipe protocol (\\.\pipe\BarrierShare.Service, one request per connection, UTF-8):
//   START \t host|receiver \t address \t base64(Barrier.pem) \t base64(trusted) \t base64(config) \t screen name
//   STOP
//   STATUS
// Reply: OK \t running(0|1) \t log path   or   ERROR \t message
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <sddl.h>
#include <tlhelp32.h>

#include <aclapi.h>
#include <atomic>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
const wchar_t* kServiceName = L"BarrierShare";
const wchar_t* kPipeName = L"\\\\.\\pipe\\BarrierShare.Service";
SERVICE_STATUS_HANDLE statusHandle = nullptr;
SERVICE_STATUS status{SERVICE_WIN32_OWN_PROCESS, SERVICE_START_PENDING, 0, NO_ERROR, 0, 0, 0};
HANDLE stopEvent = nullptr;
std::atomic<bool> stopping{false};

struct Command {
    bool host = true; std::wstring sid, address, directory, log, name;
};
std::mutex mutex;
bool wanted = false; Command command;
PROCESS_INFORMATION core{};
DWORD coreSession = 0xFFFFFFFF;
unsigned failures = 0;

std::wstring widen(const std::string& text) {
    if (text.empty()) return {};
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (length <= 0) throw std::runtime_error("Invalid text");
    std::wstring result(length, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), &result[0], length);
    return result;
}
std::string narrow(const std::wstring& text) {
    if (text.empty()) return {};
    int length = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string result(length, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), &result[0], length, nullptr, nullptr);
    return result;
}
void logLine(const std::wstring& directory, const std::string& line) {
    // Service-side notes for the diagnostics window, next to the core log.
    std::ofstream out(directory + L"\\service.log", std::ios::app | std::ios::binary);
    SYSTEMTIME t; GetLocalTime(&t);
    char stamp[32]; std::snprintf(stamp, sizeof(stamp), "[%04u-%02u-%02uT%02u:%02u:%02u] ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    out << stamp << line << "\r\n";
}
std::string base64Decode(const std::string& input) {
    static const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    if (input.size() % 4) throw std::runtime_error("Invalid encoding");
    std::string out; unsigned value = 0; int bits = 0; size_t padding = 0;
    for (size_t i = 0; i < input.size(); ++i) {
        char c = input[i];
        if (c == '=') { if (i + 2 < input.size()) throw std::runtime_error("Invalid encoding"); ++padding; continue; }
        if (padding) throw std::runtime_error("Invalid encoding");
        auto index = alphabet.find(c);
        if (index == std::string::npos) throw std::runtime_error("Invalid encoding");
        value = (value << 6) | static_cast<unsigned>(index); bits += 6;
        if (bits >= 8) { bits -= 8; out.push_back(static_cast<char>((value >> bits) & 0xFF)); }
    }
    return out;
}
std::vector<std::string> fields(const std::string& line) {
    std::vector<std::string> result; size_t start = 0;
    for (;;) { auto end = line.find('\t', start); result.push_back(line.substr(start, end == std::string::npos ? end : end - start)); if (end == std::string::npos) break; start = end + 1; }
    return result;
}
bool validIPv4(const std::string& text) {
    int parts = 0; size_t start = 0;
    while (start <= text.size()) {
        auto end = text.find('.', start); auto part = text.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part.size() > 3 || part.find_first_not_of("0123456789") != std::string::npos || std::stoi(part) > 255) return false;
        ++parts; if (end == std::string::npos) break; start = end + 1;
    }
    return parts == 4;
}
std::wstring moduleDirectory() {
    wchar_t path[MAX_PATH * 4]; DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH * 4);
    std::wstring result(path, length); return result.substr(0, result.find_last_of(L'\\'));
}
std::wstring quote(const std::wstring& value) {
    std::wstring result = L"\""; int slashes = 0;
    for (wchar_t c : value) {
        if (c == L'\\') { ++slashes; continue; }
        result.append(c == L'"' ? slashes * 2 + 1 : slashes, L'\\'); result.push_back(c); slashes = 0;
    }
    result.append(slashes * 2, L'\\'); result.push_back(L'"'); return result;
}
// Directory only SYSTEM/Administrators can change; the user named by sid may read it.
void secureDirectory(const std::wstring& path, const std::wstring& sid) {
    std::wstring sddl = L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)" + (sid.empty() ? std::wstring() : L"(A;OICI;0x1200a9;;;" + sid + L")");
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) throw std::runtime_error("Cannot build folder permissions");
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
    DWORD existing = GetFileAttributesW(path.c_str());
    if (existing != INVALID_FILE_ATTRIBUTES && (existing & FILE_ATTRIBUTE_REPARSE_POINT)) { LocalFree(descriptor); throw std::runtime_error("State folder is a link"); }
    if (existing == INVALID_FILE_ATTRIBUTES && !CreateDirectoryW(path.c_str(), &attributes)) { LocalFree(descriptor); throw std::runtime_error("Cannot create state folder"); }
    if (existing != INVALID_FILE_ATTRIBUTES) {
        BOOL present = FALSE, defaulted = FALSE; PACL dacl = nullptr; GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted);
        if (SetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, dacl, nullptr) != ERROR_SUCCESS) {
            LocalFree(descriptor); throw std::runtime_error("Cannot secure state folder");
        }
    }
    LocalFree(descriptor);
}
void writeFile(const std::wstring& path, const std::string& data) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot write state file");
    DWORD written = 0; BOOL ok = data.empty() || WriteFile(file, data.data(), static_cast<DWORD>(data.size()), &written, nullptr);
    CloseHandle(file);
    if (!ok || written != data.size()) throw std::runtime_error("Cannot write state file");
}
HANDLE winlogonToken(DWORD session) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0); PROCESSENTRY32W entry{sizeof(entry)}; HANDLE result = nullptr;
    for (BOOL more = Process32FirstW(snapshot, &entry); more && !result; more = Process32NextW(snapshot, &entry)) {
        DWORD processSession = 0;
        if (_wcsicmp(entry.szExeFile, L"winlogon.exe") || !ProcessIdToSessionId(entry.th32ProcessID, &processSession) || processSession != session) continue;
        HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, entry.th32ProcessID), token = nullptr;
        if (process && OpenProcessToken(process, TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY, &token)) {
            DuplicateTokenEx(token, MAXIMUM_ALLOWED, nullptr, SecurityImpersonation, TokenPrimary, &result); CloseHandle(token);
        }
        if (process) CloseHandle(process);
    }
    CloseHandle(snapshot);
    if (!result) throw std::runtime_error("No sign-in process in the console session");
    DWORD uiAccess = 1; SetTokenInformation(result, TokenUIAccess, &uiAccess, sizeof(uiAccess));
    return result;
}
bool coreRunning() { DWORD code = 0; return core.hProcess && GetExitCodeProcess(core.hProcess, &code) && code == STILL_ACTIVE; }
void stopCore() {
    if (core.hProcess) {
        if (coreRunning()) { TerminateProcess(core.hProcess, 0); WaitForSingleObject(core.hProcess, 5000); }
        CloseHandle(core.hProcess); CloseHandle(core.hThread); core = PROCESS_INFORMATION{};
    }
    coreSession = 0xFFFFFFFF;
}
void startCore(DWORD session) {
    stopCore();
    std::wstring bin = moduleDirectory(), profile = command.directory;
    std::wstring line = quote(bin + (command.host ? L"\\barriers.exe" : L"\\barrierc.exe")) + L" -f --no-tray --file-clipboard --profile-dir " + quote(profile) +
        L" --log " + quote(command.log) + L" --name " + command.name;
    line += command.host ? L" -c " + quote(profile + L"\\windows-windows.conf") : L" " + command.address;
    HANDLE token = winlogonToken(session);
    STARTUPINFOW startup{sizeof(startup)}; startup.lpDesktop = const_cast<wchar_t*>(L"winsta0\\default");
    std::vector<wchar_t> buffer(line.begin(), line.end()); buffer.push_back(0);
    BOOL ok = CreateProcessAsUserW(token, nullptr, buffer.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr, bin.c_str(), &startup, &core);
    DWORD error = GetLastError(); CloseHandle(token);
    if (!ok) throw std::runtime_error("Cannot start core (error " + std::to_string(error) + ")");
    coreSession = session;
    logLine(profile, "started " + std::string(command.host ? "host" : "receiver") + " core in session " + std::to_string(session));
}
// Keeps the core running in the active console session, including the sign-in screen.
void monitor() {
    while (WaitForSingleObject(stopEvent, 1000) == WAIT_TIMEOUT) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!wanted) { if (core.hProcess) stopCore(); continue; }
        DWORD session = WTSGetActiveConsoleSessionId();
        if (session == 0xFFFFFFFF) continue;
        if (coreRunning() && session == coreSession) { failures = 0; continue; }
        static ULONGLONG retryAt = 0;
        if (GetTickCount64() < retryAt) continue;
        try { startCore(session); }
        catch (const std::exception& e) {
            ++failures; retryAt = GetTickCount64() + 1000ull * (failures < 5 ? failures * 2 : 10);
            logLine(command.directory, std::string("start failed: ") + e.what());
        }
    }
}
std::wstring clientSid(HANDLE pipe) {
    if (!ImpersonateNamedPipeClient(pipe)) throw std::runtime_error("Cannot identify caller");
    HANDLE token = nullptr; BOOL ok = OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token);
    RevertToSelf();
    if (!ok) throw std::runtime_error("Cannot identify caller");
    std::vector<unsigned char> buffer(256); DWORD length = 0;
    if (!GetTokenInformation(token, TokenUser, buffer.data(), static_cast<DWORD>(buffer.size()), &length)) { buffer.resize(length); GetTokenInformation(token, TokenUser, buffer.data(), length, &length); }
    CloseHandle(token);
    wchar_t* text = nullptr;
    if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &text)) throw std::runtime_error("Cannot identify caller");
    std::wstring sid(text); LocalFree(text); return sid;
}
std::string handle(HANDLE pipe, const std::string& request) {
    ULONG session = 0;
    if (!GetNamedPipeClientSessionId(pipe, &session) || session != WTSGetActiveConsoleSessionId()) throw std::runtime_error("Only the signed-in console user can control Barrier Share");
    auto f = fields(request);
    std::lock_guard<std::mutex> lock(mutex);
    auto reply = [&]() { return "OK\t" + std::string(wanted && coreRunning() ? "1" : "0") + '\t' + narrow(command.log); };
    if (f[0] == "STATUS") return reply();
    if (f[0] == "STOP") { wanted = false; stopCore(); return reply(); }
    if (f[0] != "START" || f.size() != 7 || (f[1] != "host" && f[1] != "receiver")) throw std::runtime_error("Invalid request");
    if (f[6].empty() || f[6].size() > 32 || f[6].find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-") != std::string::npos) throw std::runtime_error("Invalid screen name");
    bool host = f[1] == "host";
    // Receiver: the host's IPv4 address, optionally with :port (used by the tests).
    if (!host) {
        auto colon = f[2].find(':'); auto port = colon == std::string::npos ? std::string("24800") : f[2].substr(colon + 1);
        if (!validIPv4(f[2].substr(0, colon)) || port.empty() || port.size() > 5 || port.find_first_not_of("0123456789") != std::string::npos || std::stoi(port) == 0 || std::stoi(port) > 65535)
            throw std::runtime_error("Invalid host address");
    }
    auto pem = base64Decode(f[3]), trusted = base64Decode(f[4]), config = base64Decode(f[5]);
    if (pem.find("PRIVATE KEY") == std::string::npos || (host && config.find("section: screens") == std::string::npos)) throw std::runtime_error("Incomplete pairing data");
    Command next; next.host = host; next.address = widen(f[2]); next.name = widen(f[6]); next.sid = clientSid(pipe);
    std::wstring state = moduleDirectory() + L"\\state";
    secureDirectory(state, L""); secureDirectory(state + L"\\" + next.sid, next.sid);
    next.directory = state + L"\\" + next.sid + (host ? L"\\profile-server" : L"\\profile");
    secureDirectory(next.directory, next.sid);
    for (auto sub : { L"\\SSL", L"\\SSL\\Fingerprints" }) secureDirectory(next.directory + sub, next.sid);
    writeFile(next.directory + L"\\SSL\\Barrier.pem", pem);
    writeFile(next.directory + (host ? L"\\SSL\\Fingerprints\\TrustedClients.txt" : L"\\SSL\\Fingerprints\\TrustedServers.txt"), trusted);
    if (host) writeFile(next.directory + L"\\windows-windows.conf", config);
    next.log = next.directory + (host ? L"\\server.log" : L"\\windows.log");
    stopCore(); command = next; wanted = true; failures = 0;
    try { startCore(WTSGetActiveConsoleSessionId()); } catch (const std::exception& e) { logLine(command.directory, std::string("start failed: ") + e.what()); }
    return reply();
}
void serve() {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    // Signed-in users may connect; requests are still limited to the console session.
    ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)", SDDL_REVISION_1, &descriptor, nullptr);
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
    while (!stopping) {
        HANDLE pipe = CreateNamedPipeW(kPipeName, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 4 * 1024 * 1024, 0, &attributes);
        if (pipe == INVALID_HANDLE_VALUE) { if (WaitForSingleObject(stopEvent, 1000) == WAIT_OBJECT_0) break; continue; }
        OVERLAPPED overlapped{}; overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        BOOL connected = ConnectNamedPipe(pipe, &overlapped);
        if (!connected && GetLastError() == ERROR_IO_PENDING) {
            HANDLE waits[2] = { overlapped.hEvent, stopEvent };
            DWORD which = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
            if (which != WAIT_OBJECT_0) { CancelIo(pipe); CloseHandle(overlapped.hEvent); CloseHandle(pipe); break; }
            DWORD ignored; connected = GetOverlappedResult(pipe, &overlapped, &ignored, FALSE);
        } else if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = TRUE;
        if (connected) {
            std::string request, reply; std::vector<char> chunk(65536); bool complete = false;
            while (request.size() < 4 * 1024 * 1024) {
                DWORD read = 0; ResetEvent(overlapped.hEvent);
                BOOL ok = ReadFile(pipe, chunk.data(), static_cast<DWORD>(chunk.size()), &read, &overlapped);
                if (!ok && GetLastError() == ERROR_IO_PENDING) {
                    if (WaitForSingleObject(overlapped.hEvent, 10000) != WAIT_OBJECT_0) { CancelIo(pipe); break; }
                    ok = GetOverlappedResult(pipe, &overlapped, &read, FALSE);
                }
                request.append(chunk.data(), read);
                if (ok) { complete = true; break; }
                if (GetLastError() != ERROR_MORE_DATA) break;
            }
            try { if (!complete) throw std::runtime_error("Incomplete request"); while (!request.empty() && (request.back() == '\n' || request.back() == '\r')) request.pop_back(); reply = handle(pipe, request); }
            catch (const std::exception& e) { reply = std::string("ERROR\t") + e.what(); }
            DWORD written = 0; ResetEvent(overlapped.hEvent);
            if (!WriteFile(pipe, reply.data(), static_cast<DWORD>(reply.size()), &written, &overlapped) && GetLastError() == ERROR_IO_PENDING)
                if (WaitForSingleObject(overlapped.hEvent, 5000) == WAIT_OBJECT_0) GetOverlappedResult(pipe, &overlapped, &written, FALSE);
            FlushFileBuffers(pipe); DisconnectNamedPipe(pipe);
        }
        CloseHandle(overlapped.hEvent); CloseHandle(pipe);
    }
    LocalFree(descriptor);
}
void report(DWORD state, DWORD exitCode = NO_ERROR) {
    status.dwCurrentState = state; status.dwWin32ExitCode = exitCode;
    status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
    if (statusHandle) SetServiceStatus(statusHandle, &status);
}
DWORD WINAPI control(DWORD code, DWORD, LPVOID, LPVOID) {
    if (code == SERVICE_CONTROL_STOP || code == SERVICE_CONTROL_SHUTDOWN) { report(SERVICE_STOP_PENDING); stopping = true; SetEvent(stopEvent); }
    return NO_ERROR;
}
void run() {
    stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::thread watcher(monitor), server(serve);
    if (statusHandle) report(SERVICE_RUNNING);
    server.join(); watcher.join();
    { std::lock_guard<std::mutex> lock(mutex); stopCore(); }
}
void WINAPI serviceMain(DWORD, LPWSTR*) {
    statusHandle = RegisterServiceCtrlHandlerExW(kServiceName, control, nullptr);
    if (!statusHandle) return;
    run(); report(SERVICE_STOPPED);
}
}

int wmain(int argc, wchar_t** argv) {
    // --console runs the same loop in the foreground for testing as an administrator.
    if (argc == 2 && std::wstring(argv[1]) == L"--console") { SetConsoleCtrlHandler([](DWORD) -> BOOL { stopping = true; SetEvent(stopEvent); return TRUE; }, TRUE); run(); return 0; }
    SERVICE_TABLE_ENTRYW table[] = { { const_cast<wchar_t*>(kServiceName), serviceMain }, { nullptr, nullptr } };
    return StartServiceCtrlDispatcherW(table) ? 0 : 1;
}
