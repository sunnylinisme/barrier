"""Actual barrierc: pinned mutual TLS -> handshake -> file -> native OLE target."""
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
processes = []
with tempfile.TemporaryDirectory(prefix="barrier-network-") as temporary:
    root = pathlib.Path(temporary)
    log_path = root / "client.log"
    try:
        def pair(*args):
            return subprocess.check_output([str(binary / "barrier-pair.exe"), *map(str, args)], text=True).strip()
        server_profile, client_profile = root / "server", root / "client"
        server_fingerprint = pair("init", server_profile)
        client_fingerprint = pair("init", client_profile)
        pair("trust", client_profile, "server", server_fingerprint)
        pair("trust", server_profile, "client", client_fingerprint)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(server_profile / "SSL/Barrier.pem")
        context.load_verify_locations(client_profile / "SSL/Barrier.pem")
        context.verify_mode = ssl.CERT_REQUIRED
        context.verify_flags = 0
        wire = root / "wire.bin"
        subprocess.run([str(binary / "native-transfer-test.exe"), "--wire-output", str(wire)], check=True)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(20)
            target = subprocess.Popen([str(binary / "native-windows-drop-test.exe"), "--network"])
            processes.append(target)
            client_log = open(root / "console.log", "w", encoding="utf-8")
            client = subprocess.Popen([str(binary / "barrierc.exe"), "-f", "--no-tray", "--name", "windows",
                "--native-file-drop", "--profile-dir", str(client_profile), "--log", str(log_path),
                "127.0.0.1:" + str(listener.getsockname()[1])], stdout=client_log, stderr=subprocess.STDOUT)
            processes.append(client)
            peer, _ = listener.accept()
            with context.wrap_socket(peer, server_side=True) as connection:
                connection.settimeout(10)
                assert hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest() == client_fingerprint.split(":", 2)[2]
                def send(message):
                    connection.sendall(struct.pack("!I", len(message)) + message)
                def exact(size):
                    chunks = bytearray()
                    while len(chunks) < size:
                        part = connection.recv(size - len(chunks))
                        if not part:
                            raise RuntimeError("Client disconnected")
                        chunks.extend(part)
                    return bytes(chunks)
                def receive():
                    length, = struct.unpack("!I", exact(4))
                    assert length <= 1024 * 1024
                    return exact(length)
                def until(code):
                    for _ in range(20):
                        message = receive()
                        if message.startswith(code):
                            return message
                        if message == b"CALV":
                            send(b"CALV")
                    raise RuntimeError("Missing response: " + repr(code))
                send(b"Barrier" + struct.pack("!HH", 1, 6))
                assert until(b"Barrier").endswith(b"windows")
                send(b"QINF")
                until(b"DINF")
                send(b"CIAK")
                send(b"CROP")
                send(b"DSOP" + struct.pack("!I", 0))
                assert until(b"CNDF") == b"CNDF" + struct.pack("!I", 1)
                send(b"CINN" + struct.pack("!HHIH", 200, 200, 42, 0))
                connection.sendall(wire.read_bytes())
                time.sleep(1)
                send(b"DMMV" + struct.pack("!HH", 210, 210))
                time.sleep(0.3)
                send(b"DMUP\x01")
                assert target.wait(timeout=10) == 0, "Native drop target did not receive the snapshot"
                send(b"COUT")
                send(b"CBYE")
        print("PASS: actual Windows client, mutually authenticated TLS, capability, production packets, native OLE drop")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        if log_path.exists():
            print(log_path.read_text(errors="replace"))
        console = root / "console.log"
        if console.exists():
            print(console.read_text(errors="replace"))
