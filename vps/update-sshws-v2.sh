#!/usr/bin/env bash
# update-sshws-v2.sh — harden the SG SSH-free payload bridge.
# v1 issues addressed (2026-10-31 session-drop reports):
#  - one direction hitting EOF/error tore down the WHOLE connection;
#    v2 half-closes politely and lets the other direction drain.
#  - no TCP keepalive anywhere on the bridge sockets; v2 sets
#    KEEPALIVE + NODELAY on both legs.
#  - bridge logged nothing, so drops were undiagnosable; v2 logs
#    connect/disconnect (with byte counts + duration) to the journal.
#  - sshd now sends ClientAlive keepalives for goldenskyvpn sessions
#    (keeps carrier NAT mappings warm).
# Byte-counter file format is UNCHANGED, so gs-sshfree-guard keeps working.
set -uo pipefail
SSHD_CFG="/etc/ssh/sshd_config"

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi

echo "== 1/3 bridge v2 =="
cp /usr/local/bin/gs-sshws.py "/usr/local/bin/gs-sshws.py.bak-$(date +%s)" 2>/dev/null || true
cat > /usr/local/bin/gs-sshws.py <<'PYEOF'
#!/usr/bin/env python3
"""gs-sshws v2: payload bridge for the GOLDENSKY SSH free key.

Accepts HTTP-upgrade-style payload connections on 127.0.0.1:18080
(fronted by Caddy on :80), replies 101, then splices raw bytes to
sshd on 127.0.0.1:22. Counts bytes to /var/lib/gs-sshfree/bytes.txt
(consumed by gs-sshfree-guard.sh). Logs connect/disconnect to stderr.
"""
import os
import socket
import sys
import threading
import time

LISTEN = ("127.0.0.1", 18080)
TARGET = ("127.0.0.1", 22)
COUNT_FILE = "/var/lib/gs-sshfree/bytes.txt"
_lock = threading.Lock()
_counters = {"up": 0, "down": 0}
_conn_seq = [0]

RESP = (b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n\r\n")


def log(msg):
    print("[gs-sshws] %s %s" % (time.strftime("%H:%M:%S"), msg),
          file=sys.stderr, flush=True)


def _load():
    try:
        with open(COUNT_FILE) as f:
            u, d = f.read().split()
            _counters["up"], _counters["down"] = int(u), int(d)
    except Exception:
        pass


def _save_locked():
    try:
        os.makedirs(os.path.dirname(COUNT_FILE), exist_ok=True)
        tmp = COUNT_FILE + ".tmp"
        with open(tmp, "w") as f:
            f.write("%d %d" % (_counters["up"], _counters["down"]))
        os.replace(tmp, COUNT_FILE)
    except Exception:
        pass


def _add(key, n):
    with _lock:
        _counters[key] += n


def _tune(sock):
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        if hasattr(socket, "TCP_KEEPIDLE"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 60)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 15)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 4)
    except OSError:
        pass


def _pipe(src, dst, key, stats):
    total = 0
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
            total += len(data)
            if total >= 262144:
                _add(key, total)
                stats[key] += total
                total = 0
    except OSError:
        pass
    finally:
        if total:
            _add(key, total)
            stats[key] += total
        # polite half-close: tell dst no more data is coming, but do
        # NOT kill the socket — the reverse pipe may still be draining.
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def _handle(client, peer):
    with _lock:
        _conn_seq[0] += 1
        cid = _conn_seq[0]
    started = time.time()
    stats = {"up": 0, "down": 0}
    server = None
    try:
        client.settimeout(30)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = client.recv(4096)
            if not chunk:
                log("#%d %s left during handshake" % (cid, peer))
                client.close()
                return
            buf += chunk
            if len(buf) > 16384:
                client.close()
                return
        client.settimeout(None)
        server = socket.create_connection(TARGET, timeout=10)
        _tune(client)
        _tune(server)
        client.sendall(RESP)
        log("#%d %s connected (101 sent)" % (cid, peer))
        t1 = threading.Thread(target=_pipe, args=(client, server, "up", stats),
                              daemon=True)
        t2 = threading.Thread(target=_pipe, args=(server, client, "down", stats),
                              daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception as exc:  # keep the daemon alive on any single failure
        log("#%d %s error: %r" % (cid, peer, exc))
    finally:
        for s in (client, server):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass
        log("#%d %s closed after %.0fs (up %d B, down %d B)"
            % (cid, peer, time.time() - started, stats["up"], stats["down"]))


def _saver():
    while True:
        time.sleep(15)
        with _lock:
            _save_locked()


def main():
    _load()
    threading.Thread(target=_saver, daemon=True).start()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(128)
    log("listening on %s:%d -> %s:%d" % (LISTEN + TARGET))
    while True:
        client, addr = srv.accept()
        threading.Thread(target=_handle, args=(client, "%s:%d" % addr),
                         daemon=True).start()


if __name__ == "__main__":
    main()
PYEOF
chmod 755 /usr/local/bin/gs-sshws.py
python3 -m py_compile /usr/local/bin/gs-sshws.py || { echo "bridge compile FAILED"; exit 1; }

echo "== 2/3 sshd keepalive for goldenskyvpn =="
cp "$SSHD_CFG" "$SSHD_CFG.bak.sshws2-$(date +%s)"
python3 - "$SSHD_CFG" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"# GS-SSHFREE-BEGIN.*?# GS-SSHFREE-END\n?", "", s, flags=re.S)
block = """# GS-SSHFREE-BEGIN
Match User goldenskyvpn Address 127.0.0.1
    PasswordAuthentication yes
    AllowTcpForwarding yes
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    ClientAliveInterval 30
    ClientAliveCountMax 10
Match User goldenskyvpn
    PasswordAuthentication no
    AllowTcpForwarding no
# GS-SSHFREE-END
"""
open(p, "w").write(s.rstrip("\n") + "\n" + block)
print("sshd block refreshed (with ClientAlive 30s x10)")
PYEOF
if ! sshd -t 2>/dev/null; then
  echo "sshd config INVALID - restoring backup."
  cp "$(ls -t $SSHD_CFG.bak.sshws2-* | head -1)" "$SSHD_CFG"
  exit 1
fi
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload

echo "== 3/3 restart bridge =="
systemctl daemon-reload
systemctl restart gs-sshws
sleep 1
systemctl is-active --quiet gs-sshws && echo "bridge v2 active" || { echo "BRIDGE NOT ACTIVE"; journalctl -u gs-sshws -n 10 --no-pager; exit 1; }
echo
echo "=== SSHWS v2 LIVE: logging + keepalive + polite half-close ==="
echo "Watch sessions with: journalctl -u gs-sshws -f"
