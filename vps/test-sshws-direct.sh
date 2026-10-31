#!/bin/bash
# GOLDENSKY Caddy-bypass test: run a SECOND copy of the (v3) bridge
# directly on public port 2080, with NO Caddy in the path.
# If sessions live on 2080 but die on 80, Caddy is the killer.
# If they die on 2080 too, the phone<->server path is the killer.
# Test traffic uses its own counter file; the 300GB guard is untouched.
set -e
SRC=/usr/local/bin/gs-sshws.py
DST=/usr/local/bin/gs-sshws-direct.py
grep -q "server.settimeout(None)" "$SRC" || { echo "STOP: live bridge is not v3 - run the v3 fix first"; exit 1; }
sed 's|LISTEN = ("127.0.0.1", 18080)|LISTEN = ("0.0.0.0", 2080)|; s|COUNT_FILE = "/var/lib/gs-sshfree/bytes.txt"|COUNT_FILE = "/var/lib/gs-sshfree/bytes-direct.txt"|' "$SRC" > "$DST"
grep -q '"0.0.0.0", 2080' "$DST" && echo "bind patched to :2080"
python3 -m py_compile "$DST" && echo "syntax OK"
cat > /etc/systemd/system/gs-sshws-direct.service <<'EOF'
[Unit]
Description=GOLDENSKY SSH bridge DIRECT test on 2080 (no Caddy)
After=network.target ssh.service
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/gs-sshws-direct.py
Restart=always
RestartSec=2
User=root
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now gs-sshws-direct >/dev/null 2>&1 || true
systemctl restart gs-sshws-direct
sleep 1
systemctl is-active gs-sshws-direct
ss -tlnp | grep 2080
python3 - <<'PYEOF'
import socket, time
s = socket.create_connection(("127.0.0.1", 2080), timeout=5)
s.sendall(b"GET / HTTP/1.1\r\nHost: d16x7replahw0e.cloudfront.net\r\nConnection: Upgrade\r\nUser-Agent: Mozilla/5.0\r\nUpgrade: websocket\r\n\r\n")
s.settimeout(5)
data = b""
end = time.time() + 5
while time.time() < end and not (b"101" in data and b"SSH-2.0" in data):
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
assert b"101" in data and b"SSH-2.0" in data, data[:80]
print("DIRECT PROOF OK: 101 + SSH banner on :2080 (no Caddy in path)")
s.close()
PYEOF
echo ""
echo "=== TEST READY ==="
echo "Make a manual profile: Host chithinphyu.info, Port 2080,"
echo "user/pass goldenskyvpn, Type Direct (payload), same payload."
echo "Use it 5-10 minutes. Journal: journalctl -u gs-sshws-direct"
