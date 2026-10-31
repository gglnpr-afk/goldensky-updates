#!/bin/bash
# setup-udpgw.sh — install the gs-udpgw UDP gateway service on this box.
#
# GOLDENSKY SSH profiles relay UDP through an SSH local forward to
# this service on 127.0.0.1:7300 (badvpn-udpgw wire protocol). It is a
# persistent root service, so even nologin/sleep-shell tunnel accounts
# (which cannot exec anything) can use UDP. Loopback-only: never
# exposed publicly. Safe to re-run (rewrites files, restarts service).
set -e
if [ "$(id -u)" != "0" ]; then echo "run as root (sudo bash)"; exit 1; fi

echo "=== 1/4: gateway program ==="
cat > /usr/local/bin/gs-udpgw <<'GSPYEOF'
#!/usr/bin/env python3
"""
gs-udpgw — UDP gateway for GOLDENSKY SSH profiles.

Speaks the badvpn-udpgw wire protocol that the app's UdpGwBridge
client implements, so the phone can relay UDP over the SSH connection:

    frame = [u16 LE size][u8 flags][u16 LE connID][addr][payload]
    size  = bytes after the size field (1 + 2 + addrLen + payloadLen)
    flags = 0x02 REBIND (new/reset association), 0x08 IPv6
    addr  = IPv4: 4-byte IP + 2-byte BE port | IPv6: 16-byte + 2-byte

Listens on 127.0.0.1:7300 (TCP). It is reached from the phone only
through an SSH local forward — never exposed publicly. One TCP
connection carries many connIDs; each connID owns one UDP socket
per address family, created on REBIND (or first use) and dropped
after 180 s idle.

Usage: gs-udpgw.py [port]        (default 7300)
"""
import socket
import struct
import sys
import threading
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7300
FLAG_REBIND = 0x02
FLAG_IPV6 = 0x08
IDLE_SECONDS = 180


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("tcp eof")
        buf += chunk
    return bytes(buf)


def build_frame(conn_id, src_ip, src_port, payload):
    v6 = ":" in src_ip
    ip = socket.inet_pton(socket.AF_INET6 if v6 else socket.AF_INET, src_ip)
    addr = ip + struct.pack("!H", src_port)
    size = 1 + 2 + len(addr) + len(payload)
    return (struct.pack("<H", size)
            + bytes([FLAG_IPV6 if v6 else 0])
            + struct.pack("<H", conn_id) + addr + payload)


class ClientConn:
    """One bridged TCP connection from the phone (via SSH forward)."""

    def __init__(self, tcp):
        self.tcp = tcp
        self.send_lock = threading.Lock()
        self.lock = threading.Lock()
        # conn_id -> {"sock4": sock|None, "sock6": sock|None, "last": ts}
        self.assoc = {}
        self.alive = True

    # ---- sending replies back to the phone ----
    def send_frame(self, data):
        with self.send_lock:
            self.tcp.sendall(data)

    # ---- per-association UDP handling ----
    def _udp_receiver(self, conn_id, sock):
        while self.alive:
            try:
                data, (src_ip, src_port) = sock.recvfrom(65535)
            except OSError:
                return
            try:
                self.send_frame(build_frame(conn_id, src_ip, src_port, data))
            except OSError:
                return
            with self.lock:
                ent = self.assoc.get(conn_id)
                if ent is not None:
                    ent["last"] = time.time()

    def _get_sock(self, conn_id, v6, rebind):
        key = "sock6" if v6 else "sock4"
        with self.lock:
            ent = self.assoc.get(conn_id)
            if ent is None:
                ent = {"sock4": None, "sock6": None, "last": time.time()}
                self.assoc[conn_id] = ent
            if rebind:
                for k in ("sock4", "sock6"):
                    if ent[k] is not None:
                        try:
                            ent[k].close()
                        except OSError:
                            pass
                        ent[k] = None
            sock = ent[key]
            if sock is None:
                fam = socket.AF_INET6 if v6 else socket.AF_INET
                sock = socket.socket(fam, socket.SOCK_DGRAM)
                sock.settimeout(None)
                ent[key] = sock
                t = threading.Thread(target=self._udp_receiver,
                                     args=(conn_id, sock), daemon=True)
                t.start()
            ent["last"] = time.time()
            return sock

    def handle_frame(self, flags, conn_id, dst_ip, dst_port, payload):
        v6 = bool(flags & FLAG_IPV6)
        sock = self._get_sock(conn_id, v6, bool(flags & FLAG_REBIND))
        try:
            sock.sendto(payload, (dst_ip, dst_port))
        except OSError:
            # stale socket (e.g. family mismatch after rebind): rebuild
            # once; if the resend also fails, drop just this packet —
            # one bad destination must never kill the bridge link.
            try:
                sock = self._get_sock(conn_id, v6, True)
                sock.sendto(payload, (dst_ip, dst_port))
            except OSError:
                pass

    # ---- main loop ----
    def run(self):
        threading.Thread(target=self._sweeper, daemon=True).start()
        try:
            while self.alive:
                hdr = recv_exact(self.tcp, 2)
                (size,) = struct.unpack("<H", hdr)
                if size < 3:
                    raise ValueError("bad frame size")
                body = recv_exact(self.tcp, size)
                flags = body[0]
                (conn_id,) = struct.unpack("<H", body[1:3])
                v6 = bool(flags & FLAG_IPV6)
                addr_len = 18 if v6 else 6
                if size < 3 + addr_len:
                    raise ValueError("short frame")
                ip = socket.inet_ntop(
                    socket.AF_INET6 if v6 else socket.AF_INET,
                    body[3:3 + addr_len - 2])
                (dst_port,) = struct.unpack("!H", body[3 + addr_len - 2:
                                                       3 + addr_len])
                payload = body[3 + addr_len:]
                self.handle_frame(flags, conn_id, ip, dst_port, payload)
        except (EOFError, OSError, ValueError):
            pass
        finally:
            self.close()

    def _sweeper(self):
        while self.alive:
            time.sleep(30)
            now = time.time()
            with self.lock:
                dead = [cid for cid, ent in self.assoc.items()
                        if now - ent["last"] > IDLE_SECONDS]
                for cid in dead:
                    ent = self.assoc.pop(cid)
                    for k in ("sock4", "sock6"):
                        if ent[k] is not None:
                            try:
                                ent[k].close()
                            except OSError:
                                pass

    def close(self):
        self.alive = False
        with self.lock:
            for ent in self.assoc.values():
                for k in ("sock4", "sock6"):
                    if ent[k] is not None:
                        try:
                            ent[k].close()
                        except OSError:
                            pass
            self.assoc.clear()
        try:
            self.tcp.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(16)
    print(f"gs-udpgw listening on {HOST}:{PORT}", flush=True)
    while True:
        try:
            tcp, _ = srv.accept()
        except OSError:
            break
        tcp.settimeout(None)  # accept() must never leave a timeout behind
        try:
            tcp.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        threading.Thread(target=ClientConn(tcp).run, daemon=True).start()


if __name__ == "__main__":
    main()
GSPYEOF
chmod 755 /usr/local/bin/gs-udpgw
python3 -m py_compile /usr/local/bin/gs-udpgw && echo "syntax OK"

echo "=== 2/4: systemd service ==="
cat > /etc/systemd/system/gs-udpgw.service <<'EOF'
[Unit]
Description=GOLDENSKY UDP gateway (udpgw protocol, loopback 7300)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/gs-udpgw 7300
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable gs-udpgw >/dev/null 2>&1 || true
# NOTE: enable --now does NOT restart an already-running service;
# restart explicitly so a re-run always lands the new code.
systemctl restart gs-udpgw
sleep 1
systemctl is-active gs-udpgw

echo "=== 3/4: protocol proof (DNS via 8.8.8.8 through the gateway) ==="
python3 - <<'PYEOF2'
import socket, struct, sys, time
# minimal DNS query: example.com A IN, id 0x4747
q = struct.pack("!HHHHHH", 0x4747, 0x0100, 1, 0, 0, 0)
for part in (b"example", b"com"):
    q += bytes([len(part)]) + part
q += b"\x00" + struct.pack("!HH", 1, 1)
tcp = socket.create_connection(("127.0.0.1", 7300), timeout=5)
tcp.settimeout(6)
addr = socket.inet_aton("8.8.8.8") + struct.pack("!H", 53)
size = 1 + 2 + len(addr) + len(q)
tcp.sendall(struct.pack("<H", size) + bytes([0x02])
            + struct.pack("<H", 1) + addr + q)
def recv_exact(n):
    buf = bytearray()
    while len(buf) < n:
        chunk = tcp.recv(n - len(buf))
        if not chunk:
            raise EOFError("eof")
        buf += chunk
    return bytes(buf)
try:
    (rsize,) = struct.unpack("<H", recv_exact(2))
    body = recv_exact(rsize)
    (cid,) = struct.unpack("<H", body[1:3])
    payload = body[9:]
    (dns_id,) = struct.unpack("!H", payload[:2])
    if cid == 1 and dns_id == 0x4747 and len(payload) > 12:
        print("UDPGW PROOF OK - DNS reply via gateway, %d bytes"
              % len(payload))
    else:
        print("UDPGW PROOF WEAK - unexpected frame (cid=%s)" % cid)
        sys.exit(2)
except Exception as e:
    print("UDPGW PROOF FAILED:", e)
    sys.exit(2)
PYEOF2

echo "=== 4/4: done ==="
echo "=== UDPGW LIVE ==="
