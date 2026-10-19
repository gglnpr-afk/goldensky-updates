#!/bin/bash
# ============================================================
# setup-stunnel.sh — wrap SSH in TLS (for GOLDENSKY SSH SSL type)
#
# Installs stunnel4 with a self-signed cert, listening on 443
# (or the first free port among 443, 8443, 4443) and forwarding
# to local SSH. The GOLDENSKY app's SSH SSL type accepts
# self-signed certs — TLS here is DPI obfuscation only, real
# auth stays at the SSH layer.
#
# Usage:  sudo bash setup-stunnel.sh [ssh_port]
# Example: sudo bash setup-stunnel.sh        # wraps 127.0.0.1:22
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash setup-stunnel.sh [ssh_port]"
  exit 1
fi

SSH_PORT=${1:-22}

echo "== 1/5 install stunnel =="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq stunnel4 openssl

echo "== 2/5 self-signed cert =="
mkdir -p /etc/stunnel
if [ ! -f /etc/stunnel/stunnel.pem ]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt \
    -subj "/CN=localhost" 2>/dev/null
  cat /etc/stunnel/stunnel.key /etc/stunnel/stunnel.crt > /etc/stunnel/stunnel.pem
  chmod 600 /etc/stunnel/stunnel.pem
  echo "cert created"
else
  echo "cert exists, reusing"
fi

echo "== 3/5 pick port =="
STUNNEL_PORT=""
for p in 443 8443 4443; do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then
    STUNNEL_PORT=$p
    break
  fi
done
[ -z "$STUNNEL_PORT" ] && { echo "ERROR: 443/8443/4443 all in use."; exit 1; }
echo "using port $STUNNEL_PORT"

echo "== 4/5 configure =="
mkdir -p /run/stunnel4
cat > /etc/stunnel/stunnel.conf <<EOF
pid = /run/stunnel4/stunnel.pid
cert = /etc/stunnel/stunnel.pem
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh]
accept = $STUNNEL_PORT
connect = 127.0.0.1:$SSH_PORT
EOF

echo "== 5/5 start =="
sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/stunnel4
systemctl enable stunnel4 >/dev/null 2>&1
systemctl restart stunnel4
sleep 2
systemctl is-active --quiet stunnel4 || { echo "ERROR: stunnel did not start."; journalctl -u stunnel4 --no-pager -n 15; exit 1; }
ufw allow ${STUNNEL_PORT}/tcp >/dev/null 2>&1 || true

echo ""
echo "==========================================================="
echo "DONE: stunnel wrapping SSH (127.0.0.1:$SSH_PORT)"
echo "  TLS port : $STUNNEL_PORT"
echo "  GOLDENSKY profile: SSH SSL type, port $STUNNEL_PORT"
echo "  NOTE: also open TCP $STUNNEL_PORT in your provider firewall."
echo "==========================================================="
