#!/usr/bin/env bash
# setup-ssh-free300.sh — GOLDENSKY SSH FREE 300GB key on this box.
# Recreates the ATOM-500MB-style key on our own server:
#   * SSH user "goldenskyvpn" (password auth, forwarding only,
#     reachable ONLY via the local bridge — not directly on :22)
#   * a tiny bridge on 127.0.0.1:18080 that answers the HTTP-upgrade
#     payload with 101 and then splices raw bytes to sshd :22,
#     counting all bytes through it
#   * Caddy (already on :80 for Temp Mail) routes requests whose
#     Host is the CloudFront domain to the bridge
#   * a guard (cron, 5 min) locks the account at >= 300 GiB counted
# Re-running = RENEW (counter reset, account unlocked).
set -uo pipefail

SSH_USER="goldenskyvpn"
SSH_PASS="goldenskyvpn"
LIMIT_BYTES=322122547200   # 300 GiB
CF_HOST="d16x7replahw0e.cloudfront.net"
BRIDGE_PORT=18080
STATE_DIR="/var/lib/gs-sshfree"
CADDYFILE="/etc/caddy/Caddyfile"

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi

echo "== 1/6 ssh user =="
if id "$SSH_USER" >/dev/null 2>&1; then
  echo "user $SSH_USER exists"
else
  useradd -m -s /usr/sbin/nologin "$SSH_USER"
  echo "user $SSH_USER created"
fi
echo "$SSH_USER:$SSH_PASS" | chpasswd
passwd -u "$SSH_USER" >/dev/null 2>&1 || true
echo "password set, account unlocked"

echo "== 2/6 sshd rules (bridge-only login, forwarding only) =="
SSHD_CFG="/etc/ssh/sshd_config"
cp "$SSHD_CFG" "$SSHD_CFG.bak.sshfree-$(date +%s)"
# strip any previous GS-SSHFREE block
python3 - "$SSHD_CFG" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
out, skip = [], False
for ln in lines:
    if ln.strip() == "# GS-SSHFREE-BEGIN":
        skip = True
    if not skip:
        out.append(ln)
    if ln.strip() == "# GS-SSHFREE-END":
        skip = False
open(p, "w").write("\n".join(out) + "\n")
PYEOF
cat >> "$SSHD_CFG" <<EOF

# GS-SSHFREE-BEGIN
Match User $SSH_USER Address 127.0.0.1
    PasswordAuthentication yes
    AllowTcpForwarding yes
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
Match User $SSH_USER
    PasswordAuthentication no
    AllowTcpForwarding no
# GS-SSHFREE-END
EOF
if ! sshd -t 2>/dev/null; then
  echo "sshd config INVALID - restoring backup"
  cp "$(ls -t $SSHD_CFG.bak.sshfree-* | head -1)" "$SSHD_CFG"
  exit 1
fi
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload
echo "sshd reloaded"

echo "== 3/6 payload bridge =="
mkdir -p "$STATE_DIR"
cat > /usr/local/bin/gs-sshws.py <<'PYEOF'
#!/usr/bin/env python3
# gs-sshws: HTTP-upgrade payload -> 101 -> raw splice to sshd.
# Counts bytes in both directions to /var/lib/gs-sshfree/bytes.txt
import os, socket, threading, time

LISTEN = ("127.0.0.1", 18080)
TARGET = ("127.0.0.1", 22)
COUNT_FILE = "/var/lib/gs-sshfree/bytes.txt"
RESP = (b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n\r\n")
lock = threading.Lock()
counters = {"up": 0, "down": 0}

def load():
    try:
        with open(COUNT_FILE) as f:
            u, d = f.read().split()
            counters["up"], counters["down"] = int(u), int(d)
    except Exception:
        pass

def save():
    try:
        os.makedirs(os.path.dirname(COUNT_FILE), exist_ok=True)
        tmp = COUNT_FILE + ".tmp"
        with open(tmp, "w") as f:
            f.write("%d %d" % (counters["up"], counters["down"]))
        os.replace(tmp, COUNT_FILE)
    except Exception:
        pass

def add(key, n):
    with lock:
        counters[key] += n

def pipe(src, dst, key):
    total = 0
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
            total += len(data)
            if total >= 262144:
                add(key, total)
                total = 0
    except OSError:
        pass
    finally:
        if total:
            add(key, total)
        try:
            dst.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

def handle(client):
    try:
        client.settimeout(30)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = client.recv(4096)
            if not chunk:
                client.close()
                return
            buf += chunk
            if len(buf) > 16384:
                client.close()
                return
        client.settimeout(None)
        server = socket.create_connection(TARGET, timeout=10)
        server.settimeout(None)  # connect timeout must NOT stay on the data socket (2026-10-20 lesson)
        client.sendall(RESP)
        t1 = threading.Thread(target=pipe, args=(client, server, "up"), daemon=True)
        t2 = threading.Thread(target=pipe, args=(server, client, "down"), daemon=True)
        t1.start(); t2.start()
        t1.join(); t2.join()
        server.close(); client.close()
    except Exception:
        try:
            client.close()
        except Exception:
            pass

def saver():
    while True:
        time.sleep(15)
        with lock:
            save()

def main():
    load()
    threading.Thread(target=saver, daemon=True).start()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(LISTEN)
    s.listen(128)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == "__main__":
    main()
PYEOF
cat > /etc/systemd/system/gs-sshws.service <<EOF
[Unit]
Description=GOLDENSKY SSH payload bridge (free key)
After=network.target ssh.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/gs-sshws.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable gs-sshws >/dev/null 2>&1
systemctl restart gs-sshws
sleep 1
systemctl is-active --quiet gs-sshws && echo "bridge active on 127.0.0.1:$BRIDGE_PORT" \
  || { echo "bridge FAILED to start"; journalctl -u gs-sshws -n 10 --no-pager; exit 1; }

echo "== 4/6 caddy route for the payload host =="
if [ ! -f "$CADDYFILE" ]; then echo "Caddyfile not found at $CADDYFILE - STOP"; exit 1; fi
cp "$CADDYFILE" "$CADDYFILE.bak.sshfree-$(date +%s)"
if grep -q "GS-SSHFREE" "$CADDYFILE"; then
  echo "caddy route already present"
else
  cat >> "$CADDYFILE" <<EOF

# GS-SSHFREE payload route
http://$CF_HOST {
	reverse_proxy 127.0.0.1:$BRIDGE_PORT
}
EOF
fi
if ! /usr/local/bin/caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
  echo "caddy config INVALID - restoring backup"
  cp "$(ls -t $CADDYFILE.bak.sshfree-* | head -1)" "$CADDYFILE"
  exit 1
fi
systemctl reload caddy
echo "caddy reloaded"

echo "== 5/6 300GB guard =="
echo "0 0" > "$STATE_DIR/bytes.txt"
rm -f "$STATE_DIR/disabled"
cat > /usr/local/bin/gs-sshfree-guard.sh <<'GEOF'
#!/usr/bin/env bash
# Locks the free SSH account once counted traffic reaches 300 GiB.
STATE_DIR="/var/lib/gs-sshfree"
LIMIT=322122547200
SSH_USER="goldenskyvpn"
read -r UP DOWN < "$STATE_DIR/bytes.txt" 2>/dev/null || { UP=0; DOWN=0; }
TOTAL=$(( ${UP:-0} + ${DOWN:-0} ))
GB=$(awk -v b="$TOTAL" 'BEGIN{printf "%.2f", b/1073741824}')
echo "SSH FREE usage: $GB GB / 300 GB (updated $(date -u +%FT%TZ))" > /root/ssh-free-usage.txt
if [ "$TOTAL" -ge "$LIMIT" ] && [ ! -f "$STATE_DIR/disabled" ]; then
  passwd -l "$SSH_USER" >/dev/null 2>&1
  pkill -u "$SSH_USER" 2>/dev/null
  touch "$STATE_DIR/disabled"
  echo "LIMIT REACHED $(date -u +%FT%TZ): account locked" >> /root/ssh-free-usage.txt
fi
GEOF
chmod +x /usr/local/bin/gs-sshfree-guard.sh
cat > /etc/cron.d/gs-sshfree-guard <<'EOF'
*/5 * * * * root /usr/local/bin/gs-sshfree-guard.sh
EOF
/usr/local/bin/gs-sshfree-guard.sh
echo "guard installed (cron 5 min, status: /root/ssh-free-usage.txt)"

echo "== 6/6 end-to-end proof through :80 =="
python3 - <<'PYEOF'
import socket, sys
payload = (b"GET / HTTP/1.1\r\n"
           b"Host: d16x7replahw0e.cloudfront.net\r\n"
           b"Connection: Upgrade\r\n"
           b"User-Agent: Mozilla/5.0\r\n"
           b"Upgrade: websocket\r\n\r\n")
try:
    s = socket.create_connection(("127.0.0.1", 80), timeout=10)
    s.sendall(payload)
    s.settimeout(10)
    data = b""
    while b"SSH-" not in data and len(data) < 4096:
        chunk = s.recv(1024)
        if not chunk:
            break
        data += chunk
    s.close()
    if b"101" in data and b"SSH-" in data:
        banner = data.split(b"\r\n\r\n", 1)[-1].split(b"\r\n")[0].decode("ascii", "replace")
        print("PROVEN: payload path works - 101 received, SSH banner:", banner)
    else:
        print("NOT PROVEN - unexpected response:", data[:200])
        sys.exit(1)
except Exception as e:
    print("NOT PROVEN - error:", e)
    sys.exit(1)
PYEOF

echo
echo "SSH FREE 300GB KEY IS LIVE on this server (port 80, user $SSH_USER)."
echo "Usage status: cat /root/ssh-free-usage.txt"
