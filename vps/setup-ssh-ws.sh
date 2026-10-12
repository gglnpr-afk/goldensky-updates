#!/bin/bash
# ============================================================
# GOLDENSKY SSH-WS setup — SSH over WebSocket payload on port 80.
# Fresh one-shot. Run as root on Ubuntu 22.04.
# Usage:  sudo bash setup-ssh-ws.sh [username] [password]
# Example: sudo bash setup-ssh-ws.sh goldenskyvpn goldenskyvpn
# Default: goldenskyvpn / goldenskyvpn
#
# What it does:
#   1. Installs OpenSSH server (port 22)
#   2. Creates user boosstvpn / password boosstvpn
#   3. Runs a WebSocket bridge on port 80 -> forwards to SSH (22)
#      (accepts the HTTP Upgrade payload, replies 101, bridges raw TCP)
#   4. Opens firewall ports 22 + 80
#
# GOLDENSKY app config:
#   Host: <server-ip> | Port: 80 | Type: Direct (payload)
#   Username: boosstvpn | Password: boosstvpn
#   Payload: GET / HTTP/1.1[crlf]Host: d16x7replahw0e.cloudfront.net[crlf]
#            Connection: Upgrade[crlf]User-Agent: Mozilla/5.0[crlf]
#            Upgrade: websocket[crlf][crlf]
#
# NOTE: also open TCP 22 + 80 in your provider's firewall panel.
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash setup-ssh-ws.sh"
  exit 1
fi

WS_PORT=80
SSH_PORT=22
SSH_USER="${1:-goldenskyvpn}"
SSH_PASS="${2:-goldenskyvpn}"

echo "== packages =="
apt-get update -qq
apt-get install -y -qq openssh-server python3 ufw > /dev/null

echo "== sshd =="
# Make sure password auth is enabled
if grep -q "^#*PasswordAuthentication" /etc/ssh/sshd_config; then
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
else
  echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
fi
systemctl enable ssh > /dev/null 2>&1 || true
systemctl restart ssh

echo "== user =="
if ! id "$SSH_USER" > /dev/null 2>&1; then
  useradd -m -s /bin/bash "$SSH_USER"
  echo "user $SSH_USER created"
fi
echo "${SSH_USER}:${SSH_PASS}" | chpasswd
passwd -u "$SSH_USER" > /dev/null 2>&1 || true
echo "password set for $SSH_USER"

echo "== ws bridge =="
cat > /usr/local/bin/ssh-ws-bridge.py <<'PYEOF'
#!/usr/bin/env python3
"""HTTP-payload -> SSH bridge.
Listens on port 80, reads and discards the HTTP payload headers,
then bridges raw TCP to local SSH (22) bidirectionally.
NOTE: does NOT send a 101 response — JSch expects the SSH banner
("SSH-2.0-...") as the first bytes, not HTTP. The payload is only
for DPI bypass; the client never reads a response."""
import socket
import threading

LISTEN_PORT = 80
SSH_HOST = "127.0.0.1"
SSH_PORT = 22

def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try: s.close()
            except Exception: pass

def handle(client):
    try:
        data = b""
        client.settimeout(10)
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                client.close()
                return
            data += chunk
            if len(data) > 16384:
                client.close()
                return
        client.settimeout(None)
        # No 101 reply — go straight to SSH so JSch sees the banner first.
        ssh = socket.create_connection((SSH_HOST, SSH_PORT), timeout=10)
        t1 = threading.Thread(target=pipe, args=(client, ssh), daemon=True)
        t2 = threading.Thread(target=pipe, args=(ssh, client), daemon=True)
        t1.start(); t2.start()
        t1.join(); t2.join()
    except Exception:
        try: client.close()
        except Exception: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(128)
    print("ssh-ws bridge: port %d -> %s:%d" % (LISTEN_PORT, SSH_HOST, SSH_PORT), flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == "__main__":
    main()
PYEOF
chmod +x /usr/local/bin/ssh-ws-bridge.py
python3 -m py_compile /usr/local/bin/ssh-ws-bridge.py && echo "bridge syntax OK"

cat > /etc/systemd/system/ssh-ws-bridge.service <<'EOF'
[Unit]
Description=SSH WebSocket Bridge (port 80 -> SSH 22)
After=network.target ssh.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-ws-bridge.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ssh-ws-bridge > /dev/null 2>&1 || true
systemctl restart ssh-ws-bridge
sleep 1

echo "== firewall =="
ufw allow ${SSH_PORT}/tcp > /dev/null 2>&1 || true
ufw allow ${WS_PORT}/tcp > /dev/null 2>&1 || true
# NOTE: also open TCP 22 + 80 in your provider's firewall panel.

echo "== status =="
systemctl is-active --quiet ssh && echo "OK: sshd running" || echo "WARN: sshd not running"
systemctl is-active --quiet ssh-ws-bridge && echo "OK: ws bridge running" || { echo "FAILED: ws bridge did not start"; exit 1; }
ss -tlnp 2>/dev/null | grep -E ":80 |:22 " | head -4 || true

echo ""
echo "==================== GOLDENSKY SSH CONFIG ===================="
echo "Host:     <this server IP>"
echo "Port:     80"
echo "Username: $SSH_USER"
echo "Password: $SSH_PASS"
echo "Type:     Direct (payload)"
echo "Payload:"
echo "GET / HTTP/1.1[crlf]Host: d16x7replahw0e.cloudfront.net[crlf]Connection: Upgrade[crlf]User-Agent: Mozilla/5.0[crlf]Upgrade: websocket[crlf][crlf]"
echo "=============================================================="
