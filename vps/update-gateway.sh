#!/bin/bash
# GOLDENSKY Temp Mail — update the gsmail gateway to the latest version
# (v2: custom username support). Safe: only the gateway API restarts;
# Mailpit, stored mail, VPN services are untouched.
set -e
curl -fsSL "https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/gateway.py" -o /opt/gsmail/gateway.py
chmod 755 /opt/gsmail/gateway.py
systemctl restart gsmail
sleep 1
curl -fsS http://127.0.0.1:8090/health && echo
echo "=== GATEWAY UPDATED ==="
