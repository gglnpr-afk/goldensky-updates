#!/bin/bash
# ============================================================
# setup-hysteria2.sh — Hysteria2 server for GOLDENSKY (UDP, fast)
#
# Installs hysteria2 with a Let's Encrypt cert (REQUIRED — the
# GOLDENSKY app verifies TLS normally, self-signed will NOT work).
# Listens on UDP 8443. Prints a ready-to-import hy2:// link.
#
# Usage:  sudo bash setup-hysteria2.sh <domain> [password]
# Example: sudo bash setup-hysteria2.sh busterzone.mobi
#
# Requirements:
#   - Domain must point to this server (DNS A record)
#   - TCP 80 must be free (for Let's Encrypt) and open in firewall
#   - UDP 8443 must be open in firewall
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash setup-hysteria2.sh <domain> [password]"
  exit 1
fi

DOMAIN=${1:-}
AUTH=${2:-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')}

if [ -z "$DOMAIN" ]; then
  echo "Usage: sudo bash setup-hysteria2.sh <domain> [password]"
  echo "Example: sudo bash setup-hysteria2.sh busterzone.mobi"
  exit 1
fi

HY2_PORT=8443

echo "== 1/5 install hysteria2 =="
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) echo "ERROR: unsupported arch $ARCH"; exit 1 ;;
esac
curl -sL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" -o /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
echo "OK: $(hysteria version 2>/dev/null | head -1)"

echo "== 2/5 Let's Encrypt cert =="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot
# Stop anything on port 80 temporarily for standalone auth
systemctl stop nginx apache2 2>/dev/null || true
certbot certonly --standalone --non-interactive --agree-tos \
  --register-unsafely-without-email \
  -d "$DOMAIN" \
  --preferred-challenges http || {
    echo "ERROR: cert failed. Check DNS points to this server and TCP 80 is open."
    exit 1
  }
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo "OK: cert issued"

echo "== 3/5 configure =="
mkdir -p /etc/hysteria
cat > /etc/hysteria/config.yaml <<EOF
listen: :$HY2_PORT

tls:
  cert: $CERT
  key: $KEY

auth:
  type: password
  password: $AUTH

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
# Auto-renew cert and restart hysteria
cat > /etc/cron.d/hysteria-cert-renew <<EOF
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl restart hysteria" 2>/dev/null
EOF

echo "== 4/5 start =="
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server (GOLDENSKY)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hysteria >/dev/null 2>&1
systemctl restart hysteria
sleep 3
systemctl is-active --quiet hysteria || { echo "ERROR: hysteria did not start."; journalctl -u hysteria --no-pager -n 20; exit 1; }
ufw allow ${HY2_PORT}/udp >/dev/null 2>&1 || true
echo "OK: hysteria running"

echo "== 5/5 build hy2 link =="
LINK="hy2://${AUTH}@${DOMAIN}:${HY2_PORT}?sni=${DOMAIN}#GOLDENSKY-HY2"

echo ""
echo "==========================================================="
echo "DONE: Hysteria2 server is ready"
echo ""
echo "Link (import via LINK / QR):"
echo "$LINK"
echo ""
echo "Details:"
echo "  Domain : $DOMAIN"
echo "  Port   : $HY2_PORT/udp"
echo "  Auth   : $AUTH"
echo ""
echo "NOTE: open UDP $HY2_PORT in your provider firewall!"
echo "==========================================================="
# Save for reference
echo "$LINK" > /root/hysteria-link.txt
echo "$DOMAIN $HY2_PORT $AUTH $(date +%F)" >> /root/hysteria-users.txt
