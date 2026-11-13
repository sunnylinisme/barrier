#!/usr/bin/env python3
"""Real helper processes, isolated loopback discovery/TLS. Never starts input capture."""
import pathlib, subprocess, socket, tempfile, threading, queue, time, sys, base64, ssl, select
BIN = pathlib.Path(sys.argv[1]).resolve()
SUFFIX = '.exe' if sys.platform == 'win32' else ''
def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]
class Agent:
    def __init__(self, profile, role, own, other):
        self.profile = profile; self.events = queue.Queue(); self.history = []
        self.p = subprocess.Popen([str(BIN / ('barrier-link' + SUFFIX)), str(profile), role, '測試 ' + role, str(own), str(other)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', bufsize=1)
        def reader():
            for line in self.p.stdout:
                parts = line.rstrip('\r\n').split('\t'); self.events.put(parts); self.history.append(parts)
        self.thread = threading.Thread(target=reader, daemon=True); self.thread.start(); self.wait('READY')
    def send(self, *parts): self.p.stdin.write('\t'.join(parts) + '\n'); self.p.stdin.flush()
    def wait(self, kind, timeout=12):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try: event = self.events.get(timeout=.2)
            except queue.Empty: continue
            if event[0] == kind: return event
            if event[0] == 'FATAL': raise AssertionError(base64.b64decode(event[1]).decode())
        raise AssertionError('Missing ' + kind + ': ' + repr(self.history[-12:]))
    def stop(self):
        if self.p.poll() is None:
            self.send('QUIT')
            try: self.p.wait(10)
            except subprocess.TimeoutExpired: self.p.kill(); self.p.wait(); raise
        self.thread.join(2)
    def clear(self):
        self.history.clear()
        while not self.events.empty(): self.events.get_nowait()
def initialize(profile):
    return subprocess.check_output([str(BIN / ('barrier-pair' + SUFFIX)), 'init', str(profile)], text=True).strip()
def invitation(host, receiver, peer):
    host.send('PAIR', peer); a=host.wait('VERIFY'); b=receiver.wait('REQUEST')
    assert a[4] == b[4] and len(a[4]) == 6, (a, b)
    return a[1], b[1]
class Impostor:
    """Advertises the saved identity but proves a different TLS certificate."""
    def __init__(self, own, claimed, pem, host_pem):
        self.udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); self.udp.bind(('127.0.0.1',own))
        self.tcp=socket.socket(); self.tcp.bind(('127.0.0.1',own)); self.tcp.listen(4)
        self.context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); self.context.load_cert_chain(str(pem)); self.context.load_verify_locations(str(host_pem)); self.context.verify_mode=ssl.CERT_REQUIRED
        self.claimed=claimed; self.stopped=False; self.handshakes=0; self.accepted=0; self.errors=[]
        def serve():
            while not self.stopped:
                ready,_,_=select.select([self.udp,self.tcp],[],[],.1)
                if self.udp in ready:
                    data,remote=self.udp.recvfrom(1024); fields=data.decode().split('\t')
                    if len(fields)==2 and fields[0]=='BSEARCH1':
                        self.udp.sendto(('BHERE1\tR\t'+base64.b64encode('偽裝電腦'.encode()).decode()+'\t'+self.claimed+'\t'+fields[1]).encode(),remote)
                if self.tcp in ready:
                    raw,_=self.tcp.accept(); self.accepted+=1; raw.settimeout(3)
                    try:
                        with self.context.wrap_socket(raw,server_side=True) as connection:
                            self.handshakes+=1
                            try: connection.recv(512)
                            except ssl.SSLError: pass
                    except (ssl.SSLError,OSError) as error: self.errors.append(str(error)); raw.close()
        self.thread=threading.Thread(target=serve,daemon=True); self.thread.start()
    def stop(self):
        self.stopped=True; self.thread.join(5); self.udp.close(); self.tcp.close()

def run():
    with tempfile.TemporaryDirectory(prefix='barrier-link-') as temp:
        root=pathlib.Path(temp); hp=root/'主控'; rp=root/'接收'; hf=initialize(hp); rf=initialize(rp)
        a,b=port(),port(); host=receiver=None
        try:
            host=Agent(hp,'host',a,b); receiver=Agent(rp,'receiver',b,a)
            assert host.wait('DEVICE')[1] == rf
            assert receiver.wait('DEVICE')[1] == hf
            # Newer peers also report their system (BSEARCH2/BHERE2) so the host can map Ctrl/Command.
            expected_system = 'windows' if sys.platform == 'win32' else 'mac' if sys.platform == 'darwin' else 'linux'
            end = time.monotonic() + 8
            while not any(e[0] == 'PLATFORM' and e[1:] == [rf, expected_system] for e in list(host.history)) and time.monotonic() < end: time.sleep(.2)
            assert any(e[0] == 'PLATFORM' and e[1:] == [rf, expected_system] for e in list(host.history)), 'Host did not learn the receiver system: %r' % host.history[-8:]

            hi,ri=invitation(host,receiver,rf)
            assert not (hp/'Peer.txt').exists() and not (rp/'Peer.txt').exists()
            host.send('ACCEPT',hi); time.sleep(.3)
            assert not (hp/'Peer.txt').exists() and not (rp/'Peer.txt').exists(), 'One-sided consent persisted trust'
            receiver.send('REJECT',ri); host.wait('CLOSED'); receiver.wait('CLOSED')
            assert not (hp/'Peer.txt').exists() and not (rp/'Peer.txt').exists()
            print('PASS: LAN discovery, equal TLS-bound short codes, no trust before both consent, decline',flush=True)
            time.sleep(2.1)
            hi,ri=invitation(host,receiver,rf); host.send('ACCEPT',hi); receiver.send('ACCEPT',ri)
            host.wait('PAIRED'); receiver.wait('PAIRED'); host.wait('CONNECT'); receiver.wait('CONNECT')
            assert (hp/'SSL/Fingerprints/TrustedClients.txt').read_text().strip()==rf
            assert (rp/'SSL/Fingerprints/TrustedServers.txt').read_text().strip()==hf
            print('PASS: two approvals persist exact TLS certificate pins and connect both roles',flush=True)
            host.stop(); receiver.stop()
            # A second receiver is added to the host's list instead of replacing the first.
            sp=root/'第二台'; sf=initialize(sp); a,b=port(),port()
            host=Agent(hp,'host',a,b); second=Agent(sp,'receiver',b,a)
            try:
                assert [e[1] for e in host.history if e[0]=='SAVED']==[rf], host.history
                assert host.wait('DEVICE')[1]==sf
                hi,ri=invitation(host,second,sf); host.send('ACCEPT',hi); second.send('ACCEPT',ri)
                host.wait('PAIRED'); second.wait('PAIRED'); second.wait('CONNECT')
                assert set((hp/'SSL/Fingerprints/TrustedClients.txt').read_text().split())=={rf,sf}
                assert (hp/'Peer.txt').read_text(encoding='utf-8').split('\n')[0::2][:2]==[rf,sf]
            finally: host.stop(); second.stop()
            print('PASS: a host keeps several paired receivers',flush=True)
            # New discovery endpoints simulate a changed network address after restarting.
            a,b=port(),port(); host=Agent(hp,'host',a,b); receiver=Agent(rp,'receiver',b,a)
            host.wait('CONNECT'); receiver.wait('CONNECT')
            assert not any(e[0] in ('VERIFY','REQUEST') for e in host.history+receiver.history)
            print('PASS: restart and rediscovery reconnect automatically without new consent',flush=True)
            assert sorted(e[1] for e in host.history if e[0]=='SAVED')==sorted([rf,sf])
            host.send('FORGET',sf); assert host.wait('REMOVED')[1]==sf
            assert (hp/'SSL/Fingerprints/TrustedClients.txt').read_text().strip()==rf
            assert (hp/'Peer.txt').read_text(encoding='utf-8').split('\n')[0]==rf
            print('PASS: forgetting one receiver keeps the others',flush=True)
            host.stop(); receiver.stop()
            rogue=root/'偽裝'; initialize(rogue); a,b=port(),port()
            impostor=Impostor(b,rf,rogue/'SSL/Barrier.pem',hp/'SSL/Barrier.pem')
            try:
                host=Agent(hp,'host',a,b); assert host.wait('DEVICE')[1]==rf
                failure=host.wait('UNAVAILABLE')
                assert 'identity changed' in base64.b64decode(failure[2]).decode(), (failure,impostor.errors)
                assert impostor.accepted>0, 'Impostor TLS endpoint was never reached'
                assert not any(e[0] in ('CONNECT','VERIFY','PAIRED') for e in host.history), 'Forged discovery established trust'
                assert (hp/'SSL/Fingerprints/TrustedClients.txt').read_text().strip()==rf
                print('PASS: forged discovery with different TLS identity cannot reconnect or replace trust',flush=True)
            finally: host.stop(); impostor.stop()
            a,b=port(),port(); host=Agent(hp,'host',a,b); receiver=Agent(rp,'receiver',b,a)
            host.wait('CONNECT'); receiver.wait('CONNECT')
            receiver.send('FORGET'); receiver.wait('REMOVED'); host.clear(); receiver.clear()
            time.sleep(6.5)
            assert not any(e[0]=='CONNECT' for e in host.history+receiver.history), 'Revoked pair reconnected'
            assert not (rp/'Peer.txt').exists() and not (rp/'SSL/Fingerprints/TrustedServers.txt').read_text().strip()
            print('PASS: forgetting a peer blocks automatic reconnect and clears trust',flush=True)
        finally:
            if host: host.stop()
            if receiver: receiver.stop()
if __name__=='__main__':
    try: run()
    except BaseException as error:
        # Annotations are readable on the checks page without signing in; logs are not.
        import traceback
        where = traceback.extract_tb(error.__traceback__)[-1]
        print('::error title=LAN discovery test::%s: %s (line %d)' % (type(error).__name__, ' '.join(str(error).split())[:900], where.lineno), flush=True)
        raise
