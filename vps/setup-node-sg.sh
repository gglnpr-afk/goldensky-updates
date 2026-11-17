#!/bin/bash
# setup-node-sg.sh - run on AWS SG (as root).
# Installs the Marzban node agent (Docker, host network) so the Marzban panel
# on AWS JP (52.194.182.108) can serve the same VLESS :8443 + SS :1080
# inbounds from this box. The native sales Xray stack on this box
# (TCP 8388/8080/25574) is production and must NOT be disturbed.
# ADDITIVE ONLY: aborts before changing anything if a needed port is taken,
# if another panel's node cert is present, or if Docker cannot be installed.
#   usage: sudo bash setup-node-sg.sh <CERT_B64 from add-node-sg.sh>
set -u
[ "$(id -u)" = "0" ] || { echo "run as root: sudo bash setup-node-sg.sh"; exit 1; }
PANEL_IP="52.194.182.108"

# ---------- certificate ----------
# Preferred source: /root/gs-node-cert.pem (sent box-to-box with scp - no
# clipboard involved). Fallback: the base64 line passed as $1.
if [ -n "${1:-}" ]; then
  echo "$1" | tr -d ' \t\r\n' | base64 -d > /tmp/gs-node-cert.pem 2>/dev/null \
    || { echo "!! certificate base64 decode failed - copy the whole line again"; exit 1; }
elif [ -f /root/gs-node-cert.pem ]; then
  cp /root/gs-node-cert.pem /tmp/gs-node-cert.pem
  echo "OK: using /root/gs-node-cert.pem (scp copy)"
else
  echo "usage: sudo bash setup-node-sg.sh [CERT_B64]"
  echo "   or first copy gs-node-cert.pem from the Marzban box to /root/ here (scp)"
  exit 1
fi
grep -q "BEGIN CERTIFICATE" /tmp/gs-node-cert.pem \
  || { echo "!! decoded text is not a certificate - copy the whole line again"; exit 1; }
if command -v openssl >/dev/null 2>&1; then
  openssl x509 -in /tmp/gs-node-cert.pem -noout >/dev/null 2>&1 \
    || { echo "!! certificate does not parse (openssl) - copy the whole line again"; exit 1; }
fi
echo "OK: certificate received"
echo "CERT-SHA256 (first 16): $(sha256sum /tmp/gs-node-cert.pem | cut -c1-16)"
echo "   ^ this must match the CERT-SHA256 printed by add-node-sg.sh"

# ---------- pre-flight (no changes yet) ----------
mkdir -p /root/gs-node-backup
ss -tlnp > /root/gs-node-backup/listeners-before.txt 2>/dev/null || true
iptables-save > /root/gs-node-backup/iptables-before.rules 2>/dev/null || true
for p in 8443 1080 62050 62051; do
  if ss -tln "( sport = :$p )" 2>/dev/null | grep -q LISTEN; then
    echo "!! TCP $p is already in use - ABORTING, nothing was changed:"
    ss -tlnp "( sport = :$p )"
    exit 1
  fi
done
echo "OK: TCP 8443 / 1080 / 62050 / 62051 are free"
if [ -f /var/lib/marzban-node/ssl_client_cert.pem ]; then
  OLD=$(sha256sum /var/lib/marzban-node/ssl_client_cert.pem | cut -c1-16)
  NEW=$(sha256sum /tmp/gs-node-cert.pem | cut -c1-16)
  if [ "$OLD" != "$NEW" ]; then
    echo "!! a DIFFERENT panel certificate is already installed on this box - ABORTING"
    echo "   (this box may already serve another panel; nothing was changed)"
    exit 1
  fi
  echo "OK: same panel certificate already present (idempotent re-run)"
fi

# ---------- docker ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker (Ubuntu/Debian official script)..."
  curl -fsSL https://get.docker.com | sh || { echo "!! Docker install failed - ABORTING"; exit 1; }
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker || { echo "!! Docker did not start - ABORTING"; exit 1; }
fi
docker compose version >/dev/null 2>&1 || { echo "!! docker compose plugin missing - ABORTING"; exit 1; }
echo "OK: docker ready ($(docker --version))"

# ---------- node files ----------
install -d -m 700 /var/lib/marzban-node /opt/gs-node
install -m 600 /tmp/gs-node-cert.pem /var/lib/marzban-node/ssl_client_cert.pem
cat > /opt/gs-node/docker-compose.yml <<'YML'
services:
  marzban-node:
    image: gozargah/marzban-node:latest
    container_name: gs-node
    restart: always
    network_mode: host
    environment:
      SERVICE_PROTOCOL: "rest"
      SERVICE_PORT: "62050"
      XRAY_API_PORT: "62051"
      SSL_CERT_FILE: "/var/lib/marzban-node/ssl_cert.pem"
      SSL_KEY_FILE: "/var/lib/marzban-node/ssl_key.pem"
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/ssl_client_cert.pem"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban-node
YML
echo "OK: node config written (/opt/gs-node/docker-compose.yml)"

# ---------- firewall ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "status: active"; then
  ufw allow from "$PANEL_IP" to any port 62050 proto tcp >/dev/null || true
  ufw allow from "$PANEL_IP" to any port 62051 proto tcp >/dev/null || true
  ufw allow 8443/tcp >/dev/null || true
  ufw allow 1080/tcp >/dev/null || true
  ufw allow 1080/udp >/dev/null || true
  echo "OK: ufw - panel may reach 62050/62051; 8443/1080 open for clients"
else
  echo "note: ufw is not active - node ports depend on the provider firewall"
fi

# ---------- start ----------
cd /opt/gs-node && docker compose up -d || { echo "!! docker compose up failed"; docker logs gs-node --tail 25 2>/dev/null; exit 1; }
sleep 8
echo ""
echo "--- node status ---"
docker ps --filter name=gs-node --format '{{.Names}}: {{.Status}}' || true
for p in 62050 62051; do
  ss -tln "( sport = :$p )" | grep -q LISTEN && echo "TCP $p: listening" || echo "TCP $p: NOT listening (check: docker logs gs-node)"
done
echo ""
echo "--- existing production services (must be untouched) ---"
printf "xray (native sales stack): %s\n" "$(systemctl is-active xray 2>/dev/null || echo n/a)" || true
for p in 8388 8080 25574; do
  ss -tln "( sport = :$p )" 2>/dev/null | grep -q LISTEN \
    && echo "TCP $p: still listening (sales stack OK)" \
    || echo "TCP $p: NOT listening (check the native sales Xray stack)"
done
echo ""
echo "=================================================================="
echo " Marzban Node (SG) - DONE"
echo "   Next: re-run add-node-sg.sh on AWS JP (the panel box) - it reconnects"
echo "   and prints the node status. 'connected' = success."
echo "   Logs if needed: docker logs gs-node --tail 30"
echo "=================================================================="
