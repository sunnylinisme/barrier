// SPDX-License-Identifier: GPL-2.0-or-later
#include "net/SecureUtils.h"
#include "net/FingerprintDatabase.h"
#include "io/filesystem.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#if !SYSAPI_WIN32
#include <sys/stat.h>
#endif

int main(int argc, char** argv)
{
    try {
        if (argc != 3 && argc != 5) throw std::runtime_error("Usage: barrier-pair init PROFILE | barrier-pair trust PROFILE server|client FINGERPRINT");
        const std::string command = argv[1];
        auto profile = barrier::fs::u8path(argv[2]);
#if !SYSAPI_WIN32
        umask(0077);
#endif
        auto directory = profile / "SSL" / "Fingerprints";
        barrier::fs::create_directories(directory);
        if (command == "init" && argc == 3) {
            auto cert = profile / "SSL" / "Barrier.pem";
            if (!barrier::fs::exists(cert)) barrier::generate_pem_self_signed_cert(cert.u8string());
            auto fingerprint = barrier::get_pem_file_cert_fingerprint(cert.u8string(), barrier::SHA256);
            barrier::FingerprintDatabase db; db.add_trusted(fingerprint); db.write(directory / "Local.txt");
            std::cout << barrier::FingerprintDatabase::to_db_line(fingerprint) << '\n';
        } else if (command == "trust" && argc == 5) {
            std::string role = argv[3];
            if (role != "server" && role != "client") throw std::runtime_error("Role must be server or client");
            auto fingerprint = barrier::FingerprintDatabase::parse_db_line(argv[4]);
            if (fingerprint.algorithm != "sha256" || fingerprint.data.size() != 32)
                throw std::runtime_error("Paste the complete v2:sha256: fingerprint from the other computer");
            auto path = directory / (role == "server" ? "TrustedServers.txt" : "TrustedClients.txt");
            barrier::FingerprintDatabase db; db.read(path); db.add_trusted(fingerprint); db.write(path);
            barrier::FingerprintDatabase verify; verify.read(path);
            if (!verify.is_trusted(fingerprint)) throw std::runtime_error("Cannot save trusted fingerprint");
            std::cout << "Peer fingerprint saved.\n";
        } else throw std::runtime_error("Invalid pairing command");
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
