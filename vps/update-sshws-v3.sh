#!/bin/bash
# GOLDENSKY SSH-free bridge v3 fix: the sshd-side socket kept the 10s
# connect timeout from create_connection() — any 10s lull in
# server->phone data killed the session (repeat of the 2026-10-20 bug,
# reintroduced in the 2026-10-30 bridge). Adds server.settimeout(None).
# The patched bridge survived a 13s idle-lull test; v2 died in it.
set -e
F=/usr/local/bin/gs-sshws.py
cp -a "$F" "$F.bak-v2"
if grep -q "server.settimeout(None)" "$F"; then
  echo "already patched - nothing to do"
else
python3 - <<'PYEOF'
s = open('/usr/local/bin/gs-sshws.py').read()
old = "server = socket.create_connection(TARGET, timeout=10)"
assert old in s, "anchor line not found - bridge differs, stop"
s = s.replace(old, old + "\n        server.settimeout(None)  # v3 fix: connect timeout must not stay on the data socket")
open('/usr/local/bin/gs-sshws.py', 'w').write(s)
print("patched")
PYEOF
fi
python3 -m py_compile "$F" && echo "syntax OK"
systemctl restart gs-sshws
sleep 1
systemctl is-active gs-sshws
echo ""
echo "=== V3 LIVE: idle lulls no longer kill the session ==="
echo "Reconnect SG-FREE and use it 5 minutes - browsing AND idle time."
