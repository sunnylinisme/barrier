"""Real Explorer source + production Windows server/hooks + mutually authenticated TLS."""
import hashlib
import pathlib
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time

binary = pathlib.Path(sys.argv[1]).resolve()
payload = b"network snapshot\n\x00\x01\xff"
processes = []
with tempfile.TemporaryDirectory(prefix="barrier-source-") as temporary:
    root = pathlib.Path(temporary)
    log = open(root / "console.log", "w", encoding="utf-8")
    try:
        def pair(*args):
            return subprocess.check_output([str(binary / "barrier-pair.exe"), *map(str, args)], text=True).strip()
        server_profile, client_profile = root / "主控設定", root / "接收設定"
        server_fingerprint = pair("init", server_profile)
        pair("init", client_profile)
        pair("trust", server_profile, "client", pair("init", client_profile))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_REQUIRED
        context.verify_flags = 0
        context.load_cert_chain(client_profile / "SSL/Barrier.pem")
        context.load_verify_locations(server_profile / "SSL/Barrier.pem")
        config = root / "server.conf"
        config.write_text("""section: screens
 windows-host:
 windows:
end
section: links
 windows-host:
  right = windows
 windows:
  left = windows-host
end
section: options
 clipboardSharing = false
end
""")
        with socket.socket() as free:
            free.bind(("127.0.0.1", 0)); port = free.getsockname()[1]
        server = subprocess.Popen([str(binary / "barriers.exe"), "-f", "--no-tray", "--name", "windows-host",
            "--native-file-drop", "--debug", "DEBUG1", "--profile-dir", str(server_profile), "-c", str(config),
            "--address", "127.0.0.1:" + str(port), "--log", str(root / "server.log")], stdout=log, stderr=subprocess.STDOUT)
        processes.append(server)
        deadline = time.monotonic() + 15
        while True:
            try:
                peer = socket.create_connection(("127.0.0.1", port), timeout=3); break
            except OSError:
                if time.monotonic() > deadline or server.poll() is not None: raise
                time.sleep(.2)
        with context.wrap_socket(peer, server_hostname="Barrier") as wire:
            wire.settimeout(15)
            assert hashlib.sha256(wire.getpeercert(binary_form=True)).hexdigest() == server_fingerprint.split(":", 2)[2]
            def send(message): wire.sendall(struct.pack("!I", len(message)) + message)
            def exact(size):
                result = bytearray()
                while len(result) < size:
                    part = wire.recv(size - len(result))
                    if not part: raise RuntimeError("Server disconnected")
                    result.extend(part)
                return bytes(result)
            def receive():
                size, = struct.unpack("!I", exact(4)); assert size <= 1024 * 1024
                return exact(size)
            hello = receive(); assert hello.startswith(b"Barrier")
            send(b"Barrier" + struct.pack("!HHI", 1, 6, 7) + b"windows")
            while True:
                message = receive()
                if message == b"QINF": send(b"DINF" + struct.pack("!hhhhhhh", 0, 0, 1024, 768, 0, 200, 200))
                if message.startswith(b"DSOP"): break
            send(b"CNDF" + struct.pack("!I", 1))
            time.sleep(.3)
            source = root / "來源資料夾"; source.mkdir()
            driver = subprocess.Popen([str(binary / "native-windows-drop-test.exe"), "--server-source", str(source)])
            processes.append(driver)
            expected_id = None; expected_size = None; expected_digest = None; received = bytearray(); completed = False
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                message = receive(); code = message[:4]
                if code == b"CALV": send(b"CALV")
                elif code == b"CINN": expected_id, = struct.unpack_from("!I", message, 8)
                elif code == b"NDFB":
                    transfer_id, expected_size, length = struct.unpack_from("!III", message, 4)
                    assert transfer_id == expected_id and expected_size == len(payload)
                    name = message[16:16 + length].decode("utf-8")
                    assert name == "跨機來源測試.txt", name
                    offset = 16 + length; length, = struct.unpack_from("!I", message, offset)
                    expected_digest = message[offset + 4:offset + 4 + length]
                    assert length == 32
                elif code == b"NDFC":
                    transfer_id, size = struct.unpack_from("!II", message, 4)
                    assert transfer_id == expected_id and size == len(message) - 12
                    received.extend(message[12:])
                elif code == b"NDFE":
                    transfer_id, = struct.unpack_from("!I", message, 4)
                    assert transfer_id == expected_id and bytes(received) == payload
                    assert hashlib.sha256(received).digest() == expected_digest
                    completed = True
                elif code == b"DMUP" and message[4:] == b"\x01":
                    assert completed, "Release arrived before the file snapshot"
                    break
            else: raise RuntimeError("Missing remote release")
            assert completed
            assert driver.wait(timeout=10) == 0
        print("PASS: actual Explorer source -> real Windows server boundary/hooks -> mutual TLS -> verified file and remote release")
    finally:
        for process in reversed(processes):
            if process.poll() is None: process.terminate()
            process.wait(timeout=10)
        log.close()
        for name in ["server.log", "console.log"]:
            if (root / name).exists(): print((root / name).read_text(errors="replace"))
