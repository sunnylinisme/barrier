"""Production Windows server/client + mutual TLS + actual Explorer copy/paste."""
import hashlib
import os
import collections
import ctypes
import select
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
# Exercise many production 32 KiB chunks, not only a tiny clipboard message.
local_bytes = bytes(range(256)) * (262144 + 1)
peer_bytes = b"distinct peer clipboard\n\xff\x00reverse" + bytes(reversed(range(256))) * 131072


def entry_point(info, direction):
    assert len(info) == 18 and info[:4] == b"DINF", "Invalid client screen information"
    x, y, width, height, _, _, _ = struct.unpack("!hhhhhhh", info[4:])
    assert width > 2 and height > 2, "Client screen is too small"
    # The direction is the receiver's position relative to its simulated host.
    return {"right": (x, y + height // 2), "left": (x + width - 1, y + height // 2),
            "up": (x + width // 2, y + height - 1), "down": (x + width // 2, y)}[direction]


def wait_cursor(expected):
    from ctypes import wintypes
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.GetPhysicalCursorPos.argtypes = [ctypes.POINTER(wintypes.POINT)]
    user32.GetPhysicalCursorPos.restype = wintypes.BOOL
    point = wintypes.POINT()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if not user32.GetPhysicalCursorPos(ctypes.byref(point)):
            raise ctypes.WinError(ctypes.get_last_error())
        # SendInput absolute coordinates can round by one physical pixel.
        if abs(point.x - expected[0]) <= 1 and abs(point.y - expected[1]) <= 1:
            return
        time.sleep(.03)
    raise AssertionError("Client pointer did not reach edge: expected %r, actual %r" % (expected, (point.x, point.y)))



class Wire:
    def __init__(self, connection, server=False):
        self.connection = connection
        self.server = server
        self.sequence = None
        self.expect_no_leave = False
        self.pending = collections.deque()
        self.incoming = bytearray()
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        connection.settimeout(12)

    def send(self, message):
        self.connection.sendall(struct.pack("!I", len(message)) + message)

    def exact(self, count):
        result = bytearray()
        while len(result) < count:
            if self.incoming:
                take = min(count - len(result), len(self.incoming))
                part = bytes(self.incoming[:take]); del self.incoming[:take]
            else:
                part = self.connection.recv(count - len(result))
            if not part:
                raise RuntimeError("Peer disconnected")
            result.extend(part)
        return bytes(result)

    def receive(self):
        message = self.pending.popleft() if self.pending else self.read_packet()
        assert not (self.expect_no_leave and message == b"COUT"), "Small entry-edge movement switched back before intentional return"
        return message

    def read_packet(self):
        size, = struct.unpack("!I", self.exact(4))
        assert size < 20 * 1024 * 1024
        message = self.exact(size)
        if message == b"CALV" and not self.server:
            self.send(b"CALV")
        return message

    def drive(self, command, counts=None, limit=25):
        # Explorer can take longer than the peer timeout. Keep servicing the wire
        # while its GUI driver runs, exactly as a real peer's event loop would.
        # With counts, protocol traffic is tallied by code and dropped instead of queued.
        process = subprocess.Popen(command)
        deadline, next_heartbeat = time.monotonic() + limit, 0
        old_timeout = self.connection.gettimeout()
        self.connection.settimeout(.1)
        try:
            while process.poll() is None:
                now = time.monotonic()
                if now >= deadline:
                    raise subprocess.TimeoutExpired(command, limit)
                if now >= next_heartbeat:
                    self.send(b"CALV"); next_heartbeat = now + 1
                if self.connection.pending() or select.select([self.connection], [], [], .1)[0]:
                    try:
                        data = self.connection.recv(65536)
                    except (socket.timeout, ssl.SSLWantReadError):
                        continue
                    if not data:
                        raise RuntimeError("Peer disconnected during Explorer operation")
                    self.incoming.extend(data)
                while len(self.incoming) >= 4:
                    size, = struct.unpack_from("!I", self.incoming)
                    assert size < 20 * 1024 * 1024
                    if len(self.incoming) < size + 4:
                        break
                    message = bytes(self.incoming[4:4 + size]); del self.incoming[:4 + size]
                    assert not (self.expect_no_leave and message == b"COUT"), "Small entry-edge movement switched back before intentional return"
                    if message == b"CALV":
                        if not self.server: self.send(b"CALV")
                    elif counts is not None:
                        counts[message[:4]] = counts.get(message[:4], 0) + 1
                    else:
                        assert len(self.pending) < 128, "GUI driver did not consume protocol traffic"
                        self.pending.append(message)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, command)
        finally:
            self.connection.settimeout(old_timeout)
            if process.poll() is None:
                process.kill()
            process.wait()

    def until(self, code):
        for _ in range(200):
            message = self.receive()
            if message.startswith(code):
                return message
        raise RuntimeError("Missing " + repr(code))

    def clipboard(self, content, sequence):
        transfer = 123456
        counter = 0
        def send(code, body=b""):
            nonlocal counter
            self.send(code + struct.pack("!I", transfer) + body)
            if self.server and counter % 32 == 0:
                self.send(b"CALV")
                self.send(b"DMMV" + struct.pack("!HH", 300, 250))
            response = self.until(b"FCAK")
            assert response == b"FCAK" + struct.pack("!II", transfer, counter)
            counter += 1
        def string(value): return struct.pack("!I", len(value)) + value
        send(b"FCBG", struct.pack("!BI", 0, sequence))
        send(b"FCEN", b"\x01" + string(name.encode()) + string(str(len(content)).encode()))
        for offset in range(0, len(content), 65536):
            send(b"FCHK", string(content[offset:offset + 65536]))
        send(b"FCFE", string(hashlib.sha256(content).digest()))
        send(b"FCDN")

    def read_clipboard(self):
        digest = hashlib.sha256(); received = 0; transfer = None; counter = 0
        expected = None
        for _ in range(10000):
            message = self.receive()
            if message.startswith(b"CINN"):
                self.sequence, = struct.unpack_from("!I", message, 8)
            code = message[:4]
            if code == b"FCBG":
                transfer, identifier, _ = struct.unpack_from("!IBI", message, 4)
                assert identifier == 0
            elif code == b"FCEN":
                identifier, kind, length = struct.unpack_from("!IBI", message, 4)
                assert identifier == transfer and kind == 1
                assert message[13:13 + length].decode() == name
                size_length, = struct.unpack_from("!I", message, 13 + length)
                expected = int(message[17 + length:17 + length + size_length])
            elif code == b"FCHK":
                identifier, length = struct.unpack_from("!II", message, 4)
                assert identifier == transfer and length == len(message) - 12 and length <= 65536
                digest.update(message[12:]); received += length
            elif code == b"FCFE":
                identifier, length = struct.unpack_from("!II", message, 4)
                assert identifier == transfer and length == 32 and message[12:] == digest.digest()
                assert expected == received
            elif code == b"FCDN":
                assert struct.unpack_from("!I", message, 4)[0] == transfer
                self.send(b"FCAK" + struct.pack("!II", transfer, counter))
                return digest.digest(), received, self.sequence
            elif code in [b"FCNO", b"FCAB"]:
                raise AssertionError("File transfer rejected: " + repr(message[:200]))
            else:
                continue
            self.send(b"FCAK" + struct.pack("!II", transfer, counter)); counter += 1
        raise RuntimeError("Missing streaming file clipboard")


# On CI one receiver run also goes through barrier-service.exe, which starts the core as SYSTEM
# with the session's winlogon token, as the installed app does. It must still copy files from Explorer.
SERVICE_RUN = os.environ.get("GITHUB_ACTIONS") == "true"
SERVICE_PIPE = r"\\.\pipe\BarrierShare.Service"
def service(*command):
    subprocess.run(["sc.exe", *command], check=False, capture_output=True)
def service_request(*fields):
    deadline = time.monotonic() + 20
    while True:
        try:
            with open(SERVICE_PIPE, "r+b", buffering=0) as pipe:
                pipe.write("\t".join(fields).encode()); reply = pipe.read(65536).decode().split("\t")
                if reply[0] != "OK": raise AssertionError("Service refused " + fields[0] + ": " + " ".join(reply))
                return reply
        except FileNotFoundError:
            if time.monotonic() > deadline: raise
            time.sleep(.3)
runs = [(role, d, False) for role in ["server", "client"] for d in ["right", "left", "up", "down"]] + ([("client", "right", True)] if SERVICE_RUN else [])
if SERVICE_RUN:
    service("stop", "BarrierShare"); service("delete", "BarrierShare")
    created = subprocess.run(["sc.exe", "create", "BarrierShare", "binPath=", '"' + str(binary / "barrier-service.exe") + '"', "start=", "demand"], capture_output=True, text=True)
    assert created.returncode == 0, created.stdout + created.stderr
    service("start", "BarrierShare")
for role, direction, via_service in runs:
    with tempfile.TemporaryDirectory(prefix="barrier-clipboard-") as temporary:
        root = pathlib.Path(temporary)
        source, destination = root / "來源", root / "目的地"
        source.mkdir(); destination.mkdir()
        expected = root / "expected.bin"; expected.write_bytes(peer_bytes)
        local_expected = root / "local.bin"; local_expected.write_bytes(local_bytes)
        core = None; service_log = None
        console = open(root / "console.log", "w", encoding="utf-8")
        try:
            def pair(*args):
                return subprocess.check_output([str(binary / "barrier-pair.exe"), *map(str, args)], text=True).strip()

            def driver(*args):
                wire.drive([str(binary / "native-windows-drop-test.exe"), *map(str, args)])

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
                    opposite = {"right": "left", "left": "right", "up": "down", "down": "up"}[direction]
                    config.write_text(("section: screens\n windows-host:\n windows:\nend\nsection: links\n windows-host:\n  right = windows\n windows:\n  left = windows-host\nend\nsection: options\n clipboardSharing = true\nend\n").replace("right = windows", direction + " = windows").replace("left = windows-host", opposite + " = windows-host"))
                    args = ["barriers.exe", "--name", "windows-host", "-c", str(config), "--address", "127.0.0.1:" + str(port)]
                    profile = server_profile
                else:
                    listener.listen(1); listener.settimeout(15)
                    args = ["barrierc.exe", "--name", "windows", "127.0.0.1:" + str(port)]
                    profile = client_profile
                args[0] = str(binary / args[0])
                args[1:1] = ["-f", "--no-tray", "--debug", "DEBUG1", "--file-clipboard", "--profile-dir", str(profile), "--log", str(root / "core.log")]
                if via_service:
                    # The pairing identity and trust travel as data, exactly as BarrierShare.exe sends them.
                    import base64
                    data = lambda path: base64.b64encode(path.read_bytes()).decode()
                    reply = service_request("START", "receiver", "127.0.0.1:" + str(port), data(client_profile / "SSL/Barrier.pem"),
                                            data(client_profile / "SSL/Fingerprints/TrustedServers.txt"), "", "windows", str(client_profile))
                    service_log = pathlib.Path(reply[2])
                else:
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
                    wire = Wire(connection, server=role == "client")
                    if role == "server":
                        assert wire.receive().startswith(b"Barrier")
                        wire.send(b"Barrier" + struct.pack("!HHI", 1, 6, 7) + b"windows")
                        while True:
                            message = wire.receive()
                            if message == b"QINF":
                                wire.send(b"DINF" + struct.pack("!hhhhhhh", 0, 0, 1024, 768, 0, 200, 200))
                            if message.startswith(b"DSOP"): break
                        wire.send(b"FCAP" + struct.pack("!I", 2))
                        assert wire.until(b"FCAP") == b"FCAP" + struct.pack("!I", 2)
                        driver("--clipboard-copy", source, local_expected)
                        wire.expect_no_leave = True
                        driver("--clipboard-cross", direction)
                        entered = wire.until(b"CINN")
                        wire.pending.appendleft(entered)
                        driver("--clipboard-edge-jitter", direction)
                        driver("--cursor-hidden")
                        digest, size, sequence = wire.read_clipboard()
                        assert digest == hashlib.sha256(local_bytes).digest() and size == len(local_bytes)
                        assert sequence is not None
                        wire.send(b"CCLP" + struct.pack("!BI", 0, sequence))
                        wire.clipboard(peer_bytes, sequence)
                        time.sleep(.3)
                        wire.expect_no_leave = False
                        driver("--clipboard-return", direction)
                        wire.until(b"COUT")
                        driver("--cursor-visible")
                        driver("--clipboard-paste", destination, expected)
                        # Fifty quick leave-and-return trips with motion still arriving during the switch;
                        # the host cursor must come back to the entry edge every time, never the centre.
                        counts = {}
                        try:
                            wire.drive([str(binary / "native-windows-drop-test.exe"), "--fast-return", direction, "50"], counts, 90)
                        except subprocess.CalledProcessError:
                            # How many trips the host really made tells a lost switch from a late one.
                            print("::error::fast return %s: screen switches seen by the receiver %r" % (direction, {k.decode(): v for k, v in counts.items()}), flush=True)
                            raise
                        assert counts.get(b"CINN", 0) >= 50 and counts.get(b"COUT", 0) >= 50, "Fast-return trips did not all switch screens: %r" % counts
                    else:
                        wire.send(b"Barrier" + struct.pack("!HH", 1, 6))
                        assert wire.until(b"Barrier").endswith(b"windows")
                        wire.send(b"QINF"); entry = entry_point(wire.until(b"DINF"), direction)
                        wire.send(b"CIAK"); wire.send(b"CROP")
                        wire.send(b"DSOP" + struct.pack("!I", 2) + b"CLPS" + struct.pack("!I", 1))
                        assert wire.until(b"FCAP") == b"FCAP" + struct.pack("!I", 2)
                        wire.send(b"FCAP" + struct.pack("!I", 2))
                        wire.send(b"CINN" + struct.pack("!hhIH", *entry, 42, 0))
                        wait_cursor(entry)
                        wire.clipboard(peer_bytes, 42)
                        time.sleep(.4)
                        driver("--clipboard-paste", destination, expected)
                        driver("--clipboard-copy", source, local_expected)
                        wire.send(b"DMMV" + struct.pack("!hh", *entry))
                        wait_cursor(entry)
                        wire.send(b"COUT")
                        digest, size, _ = wire.read_clipboard()
                        assert digest == hashlib.sha256(local_bytes).digest() and size == len(local_bytes)
                    assert (source / name).read_bytes() == local_bytes, "Source file changed"
                    assert (destination / name).read_bytes() == peer_bytes, "Paste contained stale or wrong bytes"
                    print("PASS: real Windows " + role + (" started by the service as SYSTEM" if via_service else "") + " direction=" + direction + ", simulated TLS peer, bidirectional file clipboard, actual Explorer copy/paste, distinct peer bytes and original preserved" + (", native client edge entry/return verified" if role == "client" else ", ordinary edge jitter, hidden host cursor, intentional return and 50 fast returns to the edge verified"))
        finally:
            if via_service:
                try: service_request("STOP")
                except Exception as error: print("service stop failed:", error)
                for path in [locals().get("service_log")] + ([service_log.parent / "service.log"] if locals().get("service_log") else []):
                    if path and path.exists(): print(path.read_text(errors="replace")[-20000:])
            if core is not None:
                if core.poll() is None: core.terminate()
                core.wait(timeout=10)
            console.close()
            for filename in ["core.log", "console.log"]:
                path = root / filename
                if path.exists(): print(path.read_text(errors="replace"))

if SERVICE_RUN:
    service("stop", "BarrierShare"); service("delete", "BarrierShare")
    # Leave nothing behind for later steps (the discovery test needs port 24801 free).
    time.sleep(2)
    for image in ["barrier-service.exe", "barrierc.exe", "barriers.exe", "barrier-link.exe"]:
        subprocess.run(["taskkill", "/F", "/IM", image], capture_output=True)
