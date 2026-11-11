"""Production Windows server/client + mutual TLS + actual Explorer copy/paste."""
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
name = "跨機複製測試.txt"
local_bytes = b"network snapshot\n\x00\x01\xff"
peer_bytes = b"distinct peer clipboard\n\xff\x00reverse"


def envelope(content):
    filename = name.encode("utf-8")
    file = b"NFC1" + struct.pack("!II", len(filename), len(content)) + hashlib.sha256(content).digest() + filename + content
    return struct.pack("!III", 1, 3, len(file)) + file


class Wire:
    def __init__(self, connection):
        self.connection = connection
        connection.settimeout(12)

    def send(self, message):
        self.connection.sendall(struct.pack("!I", len(message)) + message)

    def exact(self, count):
        result = bytearray()
        while len(result) < count:
            part = self.connection.recv(count - len(result))
            if not part:
                raise RuntimeError("Peer disconnected")
            result.extend(part)
        return bytes(result)

    def receive(self):
        size, = struct.unpack("!I", self.exact(4))
        assert size < 20 * 1024 * 1024
        message = self.exact(size)
        if message == b"CALV":
            self.send(b"CALV")
        return message

    def until(self, code):
        for _ in range(200):
            message = self.receive()
            if message.startswith(code):
                return message
        raise RuntimeError("Missing " + repr(code))

    def clipboard(self, data, sequence, identifier=0):
        for marker, chunk in [(1, str(len(data)).encode()), (2, data), (3, b"")]:
            self.send(b"DCLP" + struct.pack("!BIBI", identifier, sequence, marker, len(chunk)) + chunk)

    def read_clipboard(self):
        data = bytearray()
        expected = None
        sequence = None
        for _ in range(300):
            message = self.receive()
            if message.startswith(b"CINN"):
                sequence, = struct.unpack_from("!I", message, 8)
            if not message.startswith(b"DCLP"):
                continue
            identifier, _, marker, length = struct.unpack_from("!BIBI", message, 4)
            chunk = message[14:]
            assert length == len(chunk)
            if identifier != 0:
                continue
            if marker == 1:
                expected = int(chunk); data.clear()
            elif marker == 2:
                data.extend(chunk)
            elif marker == 3:
                assert expected == len(data)
                # An initial empty clipboard may precede the user's copy.
                if bytes(data) == struct.pack("!I", 0):
                    continue
                return bytes(data), sequence
        raise RuntimeError("Missing file clipboard")


for role in ["server", "client"]:
    with tempfile.TemporaryDirectory(prefix="barrier-clipboard-") as temporary:
        root = pathlib.Path(temporary)
        source, destination = root / "來源", root / "目的地"
        source.mkdir(); destination.mkdir()
        expected = root / "expected.bin"; expected.write_bytes(peer_bytes)
        core = None
        console = open(root / "console.log", "w", encoding="utf-8")
        try:
            def pair(*args):
                return subprocess.check_output([str(binary / "barrier-pair.exe"), *map(str, args)], text=True).strip()

            def driver(*args):
                subprocess.run([str(binary / "native-windows-drop-test.exe"), *map(str, args)], check=True, timeout=25)

            server_profile, client_profile = root / "主控設定", root / "接收設定"
            server_fp, client_fp = pair("init", server_profile), pair("init", client_profile)
            pair("trust", server_profile, "client", client_fp)
            pair("trust", client_profile, "server", server_fp)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT if role == "server" else ssl.PROTOCOL_TLS_SERVER)
            if role == "server":
                context.check_hostname = False
            context.verify_mode = ssl.CERT_REQUIRED
            context.verify_flags = 0
            context.load_cert_chain((client_profile if role == "server" else server_profile) / "SSL/Barrier.pem")
            context.load_verify_locations((server_profile if role == "server" else client_profile) / "SSL/Barrier.pem")
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0)); port = listener.getsockname()[1]
                if role == "server":
                    listener.close()
                    config = root / "server.conf"
                    config.write_text("section: screens\n windows-host:\n windows:\nend\nsection: links\n windows-host:\n  right = windows\n windows:\n  left = windows-host\nend\nsection: options\n clipboardSharing = true\nend\n")
                    args = ["barriers.exe", "--name", "windows-host", "-c", str(config), "--address", "127.0.0.1:" + str(port)]
                    profile = server_profile
                else:
                    listener.listen(1); listener.settimeout(15)
                    args = ["barrierc.exe", "--name", "windows", "127.0.0.1:" + str(port)]
                    profile = client_profile
                args[0] = str(binary / args[0])
                args[1:1] = ["-f", "--no-tray", "--file-clipboard", "--profile-dir", str(profile), "--log", str(root / "core.log")]
                core = subprocess.Popen(args, stdout=console, stderr=subprocess.STDOUT)
                if role == "server":
                    deadline = time.monotonic() + 15
                    while True:
                        try:
                            peer = socket.create_connection(("127.0.0.1", port), timeout=3); break
                        except OSError:
                            if time.monotonic() > deadline or core.poll() is not None: raise
                            time.sleep(.1)
                else:
                    peer, _ = listener.accept()
                with context.wrap_socket(peer, server_side=role == "client", server_hostname="Barrier" if role == "server" else None) as connection:
                    assert hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest() == (server_fp if role == "server" else client_fp).split(":", 2)[2]
                    wire = Wire(connection)
                    if role == "server":
                        assert wire.receive().startswith(b"Barrier")
                        wire.send(b"Barrier" + struct.pack("!HHI", 1, 6, 7) + b"windows")
                        while True:
                            message = wire.receive()
                            if message == b"QINF":
                                wire.send(b"DINF" + struct.pack("!hhhhhhh", 0, 0, 1024, 768, 0, 200, 200))
                            if message.startswith(b"DSOP"): break
                        driver("--clipboard-copy", source)
                        driver("--clipboard-cross")
                        received, sequence = wire.read_clipboard()
                        assert received == envelope(local_bytes), "Windows host did not send Explorer's file"
                        assert sequence is not None
                        # Windows reports one system clipboard as both Barrier IDs.
                        for identifier in [0, 1]:
                            wire.send(b"CCLP" + struct.pack("!BI", identifier, sequence))
                            wire.clipboard(envelope(peer_bytes), sequence, identifier)
                        time.sleep(.3)
                        driver("--clipboard-return")
                        wire.until(b"COUT")
                        driver("--clipboard-paste", destination, expected)
                    else:
                        wire.send(b"Barrier" + struct.pack("!HH", 1, 6))
                        assert wire.until(b"Barrier").endswith(b"windows")
                        wire.send(b"QINF"); wire.until(b"DINF")
                        wire.send(b"CIAK"); wire.send(b"CROP")
                        wire.send(b"DSOP" + struct.pack("!I", 2) + b"CLPS" + struct.pack("!I", 1))
                        wire.send(b"CINN" + struct.pack("!HHIH", 200, 200, 42, 0))
                        wire.clipboard(envelope(peer_bytes), 42)
                        time.sleep(.4)
                        driver("--clipboard-paste", destination, expected)
                        driver("--clipboard-copy", source)
                        wire.send(b"COUT")
                        received, _ = wire.read_clipboard()
                        assert received == envelope(local_bytes), "Windows receiver did not send Explorer's file"
                    assert (source / name).read_bytes() == local_bytes, "Source file changed"
                    assert (destination / name).read_bytes() == peer_bytes, "Paste contained stale or wrong bytes"
                    print("PASS: real Windows " + role + ", mutual TLS, bidirectional file clipboard, actual Explorer copy/paste, distinct peer bytes and original preserved")
        finally:
            if core is not None:
                if core.poll() is None: core.terminate()
                core.wait(timeout=10)
            console.close()
            for filename in ["core.log", "console.log"]:
                path = root / filename
                if path.exists(): print(path.read_text(errors="replace"))
