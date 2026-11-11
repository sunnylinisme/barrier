// SPDX-License-Identifier: GPL-2.0-or-later
// LAN discovery is only a hint. Trust comes from the TLS session and consent on both screens.
#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#endif
#include "net/SecureUtils.h"
#include "net/FingerprintDatabase.h"
#include "io/filesystem.h"
#include <openssl/ssl.h>
#include <openssl/rand.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <vector>
#include <cstring>
#if SYSAPI_WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
using Socket = SOCKET;
constexpr Socket invalidSocket = INVALID_SOCKET;
static void closeSocket(Socket s) { closesocket(s); }
static void nonblocking(Socket s) { u_long value = 1; if (ioctlsocket(s, FIONBIO, &value)) throw std::runtime_error("Cannot configure socket"); }
#else
#include <sys/socket.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <signal.h>
using Socket = int;
constexpr Socket invalidSocket = -1;
static void closeSocket(Socket s) { close(s); }
static void nonblocking(Socket s) { if (fcntl(s, F_SETFL, O_NONBLOCK) < 0) throw std::runtime_error("Cannot configure socket"); }
#endif
using Clock = std::chrono::steady_clock;
namespace fs = barrier::fs;
static void require(bool ok, const char* reason) { if (!ok) throw std::runtime_error(reason); }
static std::mutex outputMutex;
static void emit(const std::string& line) { std::lock_guard<std::mutex> lock(outputMutex); std::cout << line << std::endl; }
static std::vector<std::string> fields(const std::string& line) {
    std::vector<std::string> result; size_t start = 0;
    do { auto end = line.find('\t', start); result.push_back(line.substr(start, end == std::string::npos ? end : end - start)); if (end == std::string::npos) break; start = end + 1; } while (true);
    return result;
}
static std::string base64(const std::string& value) {
    std::string result(4 * ((value.size() + 2) / 3) + 1, '\0');
    int length = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(&result[0]), reinterpret_cast<const unsigned char*>(value.data()), static_cast<int>(value.size()));
    result.resize(length); return result;
}
static bool validName(const std::string& encoded) {
    if (encoded.empty() || encoded.size() > 256 || encoded.size() % 4) return false;
    std::string decoded(encoded.size(), '\0');
    int count = EVP_DecodeBlock(reinterpret_cast<unsigned char*>(&decoded[0]), reinterpret_cast<const unsigned char*>(encoded.data()), static_cast<int>(encoded.size()));
    if (count < 0) return false;
    if (encoded.back() == '=') --count;
    if (encoded.size() > 1 && encoded[encoded.size() - 2] == '=') --count;
    decoded.resize(count);
    return !decoded.empty() && decoded.size() <= 128 && std::none_of(decoded.begin(), decoded.end(), [](unsigned char c) { return c < 32 || c == 127; }) && base64(decoded) == encoded;
}
static bool validFingerprint(const std::string& fp) {
    return fp.size() == 74 && fp.compare(0, 10, "v2:sha256:") == 0 && std::all_of(fp.begin() + 10, fp.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); });
}
static std::string nonce() {
    unsigned char bytes[16]; require(RAND_bytes(bytes, sizeof(bytes)) == 1, "Random number generator failed");
    std::string result; for (auto b : bytes) { result += "0123456789abcdef"[b >> 4]; result += "0123456789abcdef"[b & 15]; } return result;
}
static sockaddr_in endpoint(const std::string& ip, unsigned port) {
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(static_cast<unsigned short>(port));
    require(port > 0 && port < 65536 && inet_pton(AF_INET, ip.c_str(), &address.sin_addr) == 1, "Invalid network address"); return address;
}
static std::string addressOf(const sockaddr_in& address) { char text[INET_ADDRSTRLEN]; require(inet_ntop(AF_INET, &address.sin_addr, text, sizeof(text)) != nullptr, "Invalid peer address"); return text; }
struct SocketOwner {
    Socket value = invalidSocket;
    explicit SocketOwner(Socket socket = invalidSocket) : value(socket) {}
    ~SocketOwner() { if (value != invalidSocket) closeSocket(value); }
    Socket release() { auto result = value; value = invalidSocket; return result; }
    SocketOwner(const SocketOwner&) = delete;
};
struct Peer { std::string fingerprint, name, ip; unsigned port = 24801; char role = 'R'; Clock::time_point seen; };
struct State {
    fs::path profile; bool host; std::string name, fingerprint; unsigned port;
    std::atomic<bool> stopping{false}, busy{false}, search{true};
    std::mutex mutex; std::map<std::string, Peer> devices; Peer saved, requested;
    bool request = false; std::string approvalId; int decision = 0; unsigned generation = 0;
    fs::path trustPath() const { return profile / "SSL" / "Fingerprints" / (host ? "TrustedClients.txt" : "TrustedServers.txt"); }
};
static void atomicWrite(const fs::path& path, const std::string& value) {
    fs::create_directories(path.parent_path()); auto temporary = path; temporary += ".new";
    { std::ofstream out; barrier::open_utf8_path(out, temporary, std::ios::binary | std::ios::trunc); out << value; out.close(); require(bool(out), "Cannot save pairing"); }
#if SYSAPI_WIN32
    require(MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0, "Cannot replace pairing file");
#else
    fs::rename(temporary, path);
#endif
}
static void loadSaved(State& state) {
    std::ifstream input; barrier::open_utf8_path(input, state.profile / "Peer.txt", std::ios::binary);
    Peer peer; std::getline(input, peer.fingerprint); std::getline(input, peer.name);
    if (!validFingerprint(peer.fingerprint) || !validName(peer.name)) return;
    barrier::FingerprintDatabase db; db.read(state.trustPath());
    if (db.is_trusted(barrier::FingerprintDatabase::parse_db_line(peer.fingerprint))) state.saved = peer;
}
static bool active(State& state, unsigned generation) { std::lock_guard<std::mutex> lock(state.mutex); return !state.stopping && state.generation == generation; }
static void waitSocket(Socket socket, bool write) {
    fd_set ready; FD_ZERO(&ready); FD_SET(socket, &ready); timeval timeout{0, 100000};
    select(static_cast<int>(socket) + 1, write ? nullptr : &ready, write ? &ready : nullptr, nullptr, &timeout);
}
struct Session {
    State& state; unsigned generation; SocketOwner socket; SSL* ssl = nullptr; Clock::time_point deadline = Clock::now() + std::chrono::seconds(75); std::string pending;
    Session(State& s, unsigned g, Socket fd, SSL_CTX* context) : state(s), generation(g), socket(fd), ssl(SSL_new(context)) {
        require(ssl != nullptr, "Cannot create secure session"); nonblocking(fd); require(SSL_set_fd(ssl, static_cast<int>(fd)) == 1, "Cannot attach secure socket");
    }
    ~Session() { if (ssl) SSL_free(ssl); }
    void check() { require(active(state, generation), "Pairing cancelled"); require(Clock::now() < deadline, "Pairing timed out; try again"); }
    void again(int result) {
        int error = SSL_get_error(ssl, result);
        require(error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE, "Secure connection closed");
        waitSocket(socket.value, error == SSL_ERROR_WANT_WRITE); check();
    }
    void handshake(bool server) {
        auto oldDeadline = deadline; deadline = Clock::now() + std::chrono::seconds(8);
        for (;;) { check(); int r = server ? SSL_accept(ssl) : SSL_connect(ssl); if (r == 1) break; again(r); }
        deadline = oldDeadline;
    }
    void write(const std::string& line) {
        std::string bytes = line + '\n'; size_t sent = 0;
        while (sent < bytes.size()) { check(); int n = SSL_write(ssl, bytes.data() + sent, static_cast<int>(bytes.size() - sent)); if (n > 0) sent += n; else again(n); }
    }
    bool poll(std::string& line) {
        check();
        auto newline = pending.find('\n');
        if (newline != std::string::npos) { line = pending.substr(0, newline); pending.erase(0, newline + 1); return true; }
        char data[512]; int n = SSL_read(ssl, data, sizeof(data));
        if (n > 0) { pending.append(data, n); require(pending.size() <= 1024, "Oversized pairing message"); return poll(line); }
        again(n); return false;
    }
    std::string read() { std::string line; while (!poll(line)) {} return line; }
    std::string peerFingerprint() {
        std::unique_ptr<X509, decltype(&X509_free)> cert(SSL_get1_peer_certificate(ssl), X509_free);
        require(cert != nullptr, "Peer did not prove its identity");
        unsigned char digest[EVP_MAX_MD_SIZE]; unsigned length = 0;
        require(X509_digest(cert.get(), EVP_sha256(), digest, &length) == 1 && length == 32, "Cannot verify peer certificate");
        barrier::FingerprintData fp; fp.algorithm = "sha256"; fp.data.assign(digest, digest + length); return barrier::FingerprintDatabase::to_db_line(fp);
    }
    std::string shortCode() {
        unsigned char bytes[32]; const char* label = "EXPORTER-Barrier-Share-Pairing-v1";
        require(SSL_export_keying_material(ssl, bytes, sizeof(bytes), label, strlen(label), nullptr, 0, 0) == 1, "Cannot verify pairing session");
        uint32_t value = (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16) | (uint32_t(bytes[2]) << 8) | bytes[3];
        auto code = std::to_string(value % 1000000); return std::string(6 - code.size(), '0') + code;
    }
};
static void runSession(State& state, SSL_CTX* context, Socket accepted, Peer peer, bool automatic) {
    unsigned generation; { std::lock_guard<std::mutex> lock(state.mutex); generation = state.generation; }
    bool incoming = accepted != invalidSocket, resume = automatic; std::string requestId;
    try {
        SocketOwner connection(incoming ? accepted : socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
        require(connection.value != invalidSocket, "Cannot create pairing connection");
        if (!incoming) {
            nonblocking(connection.value); auto remote = endpoint(peer.ip, peer.port);
            if (connect(connection.value, reinterpret_cast<sockaddr*>(&remote), sizeof(remote)) != 0) {
                auto deadline = Clock::now() + std::chrono::seconds(5);
                for (;;) {
                    require(active(state, generation) && Clock::now() < deadline, "Cannot reach this computer");
                    fd_set ready; FD_ZERO(&ready); FD_SET(connection.value, &ready); timeval timeout{0, 100000};
                    if (select(static_cast<int>(connection.value) + 1, nullptr, &ready, nullptr, &timeout) > 0) {
                        int error = 0;
#if SYSAPI_WIN32
                        int length = sizeof(error);
#else
                        socklen_t length = sizeof(error);
#endif
                        require(getsockopt(connection.value, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &length) == 0 && !error, "Cannot reach this computer"); break;
                    }
                }
            }
        }
        Session session(state, generation, connection.release(), context); session.handshake(incoming);
        const auto fingerprint = session.peerFingerprint();
        if (incoming) {
            auto hello = fields(session.read());
            require(hello.size() == 3 && hello[0] == "BPAIR1" && (hello[1] == "PAIR" || hello[1] == "RESUME") && validName(hello[2]), "Invalid pairing invitation");
            peer.fingerprint = fingerprint; peer.name = hello[2]; resume = hello[1] == "RESUME";
            if (resume) { std::lock_guard<std::mutex> lock(state.mutex); require(state.saved.fingerprint == fingerprint, "This computer is not paired; send a new invitation"); }
            session.write("BREADY1\t" + state.name);
        } else {
            require(fingerprint == peer.fingerprint, "Computer identity changed; search again");
            session.write("BPAIR1\t" + std::string(resume ? "RESUME" : "PAIR") + '\t' + state.name);
            auto ready = fields(session.read()); require(ready.size() == 2 && ready[0] == "BREADY1" && validName(ready[1]), "Invalid pairing response"); peer.name = ready[1];
        }
        if (!resume) {
            requestId = nonce(); { std::lock_guard<std::mutex> lock(state.mutex); state.approvalId = requestId; state.decision = 0; }
            emit(std::string(incoming ? "REQUEST" : "VERIFY") + '\t' + requestId + '\t' + peer.name + '\t' + fingerprint + '\t' + session.shortCode());
        }
        bool localYes = false, remoteYes = false;
        while (!localYes || !remoteYes) {
            session.check(); int decision = 1;
            if (!resume) { std::lock_guard<std::mutex> lock(state.mutex); decision = state.decision; }
            if (decision < 0) { session.write("NO"); throw std::runtime_error("Pairing declined"); }
            if (decision > 0 && !localYes) { session.write("YES"); localYes = true; }
            std::string answer;
            if (!remoteYes && session.poll(answer)) { require(answer == "YES", "The other computer declined pairing"); remoteYes = true; }
            else if (remoteYes && !localYes) std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        if (!resume) {
            std::lock_guard<std::mutex> lock(state.mutex);
            require(state.generation == generation && !state.stopping, "Pairing cancelled");
            atomicWrite(state.trustPath(), peer.fingerprint + '\n');
            atomicWrite(state.profile / "Peer.txt", peer.fingerprint + '\n' + peer.name + '\n'); state.saved = peer;
        }
        session.write("SAVED"); require(session.read() == "SAVED", "Peer did not finish saving pairing");
        { std::lock_guard<std::mutex> lock(state.mutex);
            require(state.generation == generation, "Pairing cancelled"); state.saved.ip = peer.ip;
            if (!resume) emit("PAIRED\t" + peer.fingerprint + '\t' + peer.name);
            emit("CONNECT\t" + peer.fingerprint + '\t' + peer.name + '\t' + peer.ip);
        }
    } catch (const std::exception& error) {
        if (!state.stopping) {
            if (!resume) emit("ERROR\t" + base64(error.what()));
            else if (!incoming) emit("UNAVAILABLE\t" + peer.fingerprint + '\t' + base64(error.what()));
        }
    }
    if (!requestId.empty()) emit("CLOSED\t" + requestId);
    { std::lock_guard<std::mutex> lock(state.mutex); state.approvalId.clear(); state.decision = 0; }
    state.busy = false;
}
static std::vector<std::string> broadcastAddresses() {
    std::vector<std::string> result{"255.255.255.255"};
#if SYSAPI_WIN32
    ULONG size = 16384; std::vector<unsigned char> storage(size);
    auto adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
    ULONG status = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, nullptr, adapters, &size);
    if (status == ERROR_BUFFER_OVERFLOW) { storage.resize(size); adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data()); status = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, nullptr, adapters, &size); }
    if (status == NO_ERROR) for (auto a = adapters; a; a = a->Next) if (a->OperStatus == IfOperStatusUp) for (auto u = a->FirstUnicastAddress; u; u = u->Next) {
        if (u->Address.lpSockaddr->sa_family != AF_INET || u->OnLinkPrefixLength == 0 || u->OnLinkPrefixLength > 30) continue;
        auto ip = *reinterpret_cast<sockaddr_in*>(u->Address.lpSockaddr); uint32_t mask = 0xffffffffu << (32 - u->OnLinkPrefixLength);
        ip.sin_addr.s_addr = htonl(ntohl(ip.sin_addr.s_addr) | ~mask); result.push_back(addressOf(ip));
    }
#else
    ifaddrs* interfaces = nullptr;
    if (getifaddrs(&interfaces) == 0) {
        for (auto item = interfaces; item; item = item->ifa_next) if (item->ifa_addr && item->ifa_broadaddr && item->ifa_addr->sa_family == AF_INET && (item->ifa_flags & IFF_UP) && (item->ifa_flags & IFF_BROADCAST)) result.push_back(addressOf(*reinterpret_cast<sockaddr_in*>(item->ifa_broadaddr)));
        freeifaddrs(interfaces);
    }
#endif
    std::sort(result.begin(), result.end()); result.erase(std::unique(result.begin(), result.end()), result.end()); return result;
}
static void network(State& state, const std::string& testTarget) {
    std::thread worker;
    std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> context(nullptr, SSL_CTX_free);
    try {
        context.reset(SSL_CTX_new(TLS_method())); require(context != nullptr, "Cannot initialize TLS");
        SSL_CTX_set_min_proto_version(context.get(), TLS1_2_VERSION);
        // Self-signed identities are authorized only after matching TLS-bound codes or saved pins.
        SSL_CTX_set_verify(context.get(), SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, [](int, X509_STORE_CTX*) { return 1; });
        auto pem = (state.profile / "SSL" / "Barrier.pem").u8string();
        require(SSL_CTX_use_certificate_file(context.get(), pem.c_str(), SSL_FILETYPE_PEM) == 1 && SSL_CTX_use_PrivateKey_file(context.get(), pem.c_str(), SSL_FILETYPE_PEM) == 1 && SSL_CTX_check_private_key(context.get()) == 1, "Cannot load local pairing identity");
        SocketOwner udp(socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)), listener(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
        require(udp.value != invalidSocket && listener.value != invalidSocket, "Cannot create discovery service");
        int enabled = 1; setsockopt(udp.value, SOL_SOCKET, SO_BROADCAST, reinterpret_cast<const char*>(&enabled), sizeof(enabled));
#if !SYSAPI_WIN32
        setsockopt(listener.value, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
#endif
        auto local = endpoint(testTarget.empty() ? "0.0.0.0" : "127.0.0.1", state.port);
        require(bind(udp.value, reinterpret_cast<sockaddr*>(&local), sizeof(local)) == 0 && bind(listener.value, reinterpret_cast<sockaddr*>(&local), sizeof(local)) == 0 && listen(listener.value, 4) == 0, "Discovery port is busy; close the other Barrier Share window");
        nonblocking(udp.value); nonblocking(listener.value);
        auto lastSearch = Clock::time_point{}, lastResume = Clock::time_point{}, lastInvitation = Clock::time_point{}; std::string query;
        auto launch = [&](Socket accepted, Peer peer, bool automatic) {
            if (state.busy.exchange(true)) { if (accepted != invalidSocket) closeSocket(accepted); return; }
            if (worker.joinable()) worker.join();
            worker = std::thread(runSession, std::ref(state), context.get(), accepted, peer, automatic);
        };
        emit("READY\t" + state.fingerprint);
        while (!state.stopping) {
            auto now = Clock::now();
            if (state.search.exchange(false) || now - lastSearch > std::chrono::seconds(3)) {
                lastSearch = now; query = nonce(); auto message = "BSEARCH1\t" + query;
                auto targets = testTarget.empty() ? broadcastAddresses() : std::vector<std::string>{"127.0.0.1"};
                unsigned port = testTarget.empty() ? 24801 : static_cast<unsigned>(std::stoul(testTarget));
                for (const auto& ip : targets) { auto target = endpoint(ip, port); sendto(udp.value, message.data(), static_cast<int>(message.size()), 0, reinterpret_cast<sockaddr*>(&target), sizeof(target)); }
            }
            fd_set read; FD_ZERO(&read); FD_SET(udp.value, &read); FD_SET(listener.value, &read); timeval timeout{0, 100000};
            select(static_cast<int>(std::max(udp.value, listener.value)) + 1, &read, nullptr, nullptr, &timeout);
            if (FD_ISSET(udp.value, &read)) {
                char bytes[1024]; sockaddr_in from{};
#if SYSAPI_WIN32
                int length = sizeof(from);
#else
                socklen_t length = sizeof(from);
#endif
                int count = recvfrom(udp.value, bytes, sizeof(bytes), 0, reinterpret_cast<sockaddr*>(&from), &length);
                if (count > 0 && count < 512) {
                    auto f = fields(std::string(bytes, count));
                    if (f.size() == 2 && f[0] == "BSEARCH1" && f[1].size() == 32 && std::all_of(f[1].begin(), f[1].end(), [](char c){ return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); })) {
                        auto reply = "BHERE1\t" + std::string(state.host ? "H" : "R") + '\t' + state.name + '\t' + state.fingerprint + '\t' + f[1];
                        sendto(udp.value, reply.data(), static_cast<int>(reply.size()), 0, reinterpret_cast<sockaddr*>(&from), length);
                    } else if (f.size() == 5 && f[0] == "BHERE1" && f[1] == (state.host ? "R" : "H") && validName(f[2]) && validFingerprint(f[3]) && f[3] != state.fingerprint && f[4] == query) {
                        Peer p{f[3], f[2], addressOf(from), ntohs(from.sin_port), f[1][0], now};
                        { std::lock_guard<std::mutex> lock(state.mutex);
                            auto existing = state.devices.find(p.fingerprint);
                            // Keep a responding interface stable on computers with both Wi-Fi and Ethernet.
                            if (existing != state.devices.end() && (existing->second.ip != p.ip || existing->second.port != p.port) && now - existing->second.seen < std::chrono::seconds(7)) continue;
                            if (state.devices.size() < 128 || existing != state.devices.end()) state.devices[p.fingerprint] = p; else continue;
                        }
                        emit("DEVICE\t" + p.fingerprint + '\t' + p.name + '\t' + p.ip + '\t' + std::to_string(p.port) + '\t' + p.role);
                    }
                }
            }
            if (FD_ISSET(listener.value, &read)) {
                sockaddr_in from{};
#if SYSAPI_WIN32
                int length = sizeof(from);
#else
                socklen_t length = sizeof(from);
#endif
                Socket fd = accept(listener.value, reinterpret_cast<sockaddr*>(&from), &length);
                if (fd != invalidSocket) {
                    if (state.host || state.busy || now - lastInvitation < std::chrono::seconds(2)) closeSocket(fd);
                    else { lastInvitation = now; Peer peer; peer.ip = addressOf(from); launch(fd, peer, false); }
                }
            }
            Peer pending; bool start = false, automatic = false;
            { std::lock_guard<std::mutex> lock(state.mutex);
                for (auto it = state.devices.begin(); it != state.devices.end();) {
                    if (now - it->second.seen > std::chrono::seconds(12)) { emit("GONE\t" + it->first); it = state.devices.erase(it); } else ++it;
                }
                if (!state.busy && state.request) { pending = state.requested; state.request = false; start = true; }
                else if (!state.busy && state.host && !state.saved.fingerprint.empty() && now - lastResume > std::chrono::seconds(5)) {
                    auto found = state.devices.find(state.saved.fingerprint);
                    if (found != state.devices.end()) { pending = found->second; start = true; automatic = true; }
                }
            }
            if (start) { lastResume = now; launch(invalidSocket, pending, automatic); }
        }
        // SSL_CTX must outlive its session worker, including during shutdown.
        if (worker.joinable()) worker.join();
    } catch (const std::exception& error) { state.stopping = true; emit("FATAL\t" + base64(error.what())); }
    if (worker.joinable()) worker.join();
}
int main(int argc, char** argv) {
    try {
        require(argc == 4 || argc == 6, "Usage: barrier-link PROFILE host|receiver NAME [LOCAL_TEST_PORT PEER_TEST_PORT]");
#if SYSAPI_WIN32
        WSADATA data; require(WSAStartup(MAKEWORD(2, 2), &data) == 0, "Cannot initialize networking");
#else
        umask(0077); signal(SIGPIPE, SIG_IGN);
#endif
        State state; state.profile = fs::u8path(argv[1]); std::string role = argv[2]; require(role == "host" || role == "receiver", "Invalid role"); state.host = role == "host";
        std::string name = argv[3]; if (name.size() > 128) name.resize(128); name.erase(std::remove_if(name.begin(), name.end(), [](unsigned char c){ return c < 32 || c == 127; }), name.end()); if (name.empty()) name = "Computer";
        state.name = base64(name); state.port = argc == 6 ? static_cast<unsigned>(std::stoul(argv[4])) : 24801;
        state.fingerprint = barrier::FingerprintDatabase::to_db_line(barrier::get_pem_file_cert_fingerprint((state.profile / "SSL" / "Barrier.pem").u8string(), barrier::SHA256)); loadSaved(state);
        if (!state.saved.fingerprint.empty()) emit("SAVED\t" + state.saved.fingerprint + '\t' + state.saved.name);
        std::thread service(network, std::ref(state), argc == 6 ? argv[5] : "");
        std::string line;
        while (std::getline(std::cin, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.size() > 1024) continue;
            auto f = fields(line);
            try {
                if (f[0] == "QUIT") break;
                if (f[0] == "SEARCH") state.search = true;
                else if (f.size() == 2 && f[0] == "PAIR") {
                    std::lock_guard<std::mutex> lock(state.mutex); require(state.host, "Select the receiver from the host computer"); require(!state.busy && !state.request, "Another invitation is in progress");
                    auto found = state.devices.find(f[1]); require(found != state.devices.end(), "Computer is offline; search again"); state.requested = found->second; state.request = true;
                } else if (f.size() == 2 && (f[0] == "ACCEPT" || f[0] == "REJECT")) {
                    std::lock_guard<std::mutex> lock(state.mutex); if (state.approvalId == f[1]) state.decision = f[0] == "ACCEPT" ? 1 : -1;
                } else if (f[0] == "FORGET") {
                    std::lock_guard<std::mutex> lock(state.mutex); ++state.generation; state.decision = -1; state.request = false; state.saved = Peer{};
                    atomicWrite(state.trustPath(), ""); std::error_code error; fs::remove(state.profile / "Peer.txt", error); require(!error, "Cannot remove saved pairing"); state.saved = Peer{}; emit("REMOVED");
                }
            } catch (const std::exception& error) { emit("ERROR\t" + base64(error.what())); }
        }
        state.stopping = true; service.join(); return 0;
    } catch (const std::exception& error) { emit("FATAL\t" + base64(error.what())); return 1; }
}
