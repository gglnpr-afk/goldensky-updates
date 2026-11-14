#!/bin/bash
# setup-node-jp.sh - run on FirstByte JP (as root).
# Installs the Marzban node agent (Docker, host network) so the Marzban panel
# can serve the same VLESS :443 + SS :1080 inbounds from this box.
# ADDITIVE ONLY: aborts before changing anything if a needed port is taken,
# if another panel's node cert is present, or if Docker cannot be installed.
#   usage: sudo bash setup-node-jp.sh <CERT_B64 from add-node-jp.sh>
set -u
[ "$(id -u)" = "0" ] || { echo "run as root: sudo bash setup-node-jp.sh <CERT_B64>"; exit 1; }
B64="${1:-}"
[ -n "$B64" ] || { echo "usage: sudo bash setup-node-jp.sh <CERT_B64 from add-node-jp.sh>"; exit 1; }
PANEL_IP="83.147.235.168"

# ---------- certificate ----------
echo "$B64" | tr -d ' \t\r\n' | base64 -d > /tmp/gs-node-cert.pem 2>/dev/null \
  || { echo "!! certificate base64 decode failed - copy the whole line again"; exit 1; }
grep -q "BEGIN CERTIFICATE" /tmp/gs-node-cert.pem \
  || { echo "!! decoded text is not a certificate - copy the whole line again"; exit 1; }
if command -v openssl >/dev/null 2>&1; then
  openssl x509 -in /tmp/gs-node-cert.pem -noout >/dev/null 2>&1 \
    || { echo "!! certificate does not parse (openssl) - copy the whole line again"; exit 1; }
fi
echo "OK: certificate received"
echo "CERT-SHA256 (first 16): $(sha256sum /tmp/gs-node-cert.pem | cut -c1-16)"
echo "   ^ this must match the CERT-SHA256 printed by add-node-jp.sh"

# ---------- pre-flight (no changes yet) ----------
mkdir -p /root/gs-node-backup
ss -tlnp > /root/gs-node-backup/listeners-before.txt 2>/dev/null || true
iptables-save > /root/gs-node-backup/iptables-before.rules 2>/dev/null || true
for p in 443 1080 62050 62051; do
  if ss -tln "( sport = :$p )" 2>/dev/null | grep -q LISTEN; then
    echo "!! TCP $p is already in use - ABORTING, nothing was changed:"
    ss -tlnp "( sport = :$p )"
    exit 1
  fi
done
echo "OK: TCP 443 / 1080 / 62050 / 62051 are free"
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
  ufw allow 443/tcp >/dev/null || true
  ufw allow 1080/tcp >/dev/null || true
  echo "OK: ufw - panel may reach 62050/62051; 443/1080 open for clients"
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
wg show interfaces 2>/dev/null | sed 's/^/WireGuard interfaces: /' || echo "WireGuard: (wg tool output unavailable)"
for s in sing-box xray gs-hy2-main; do
  printf "%s: %s\n" "$s" "$(systemctl is-active $s 2>/dev/null || echo n/a)"
done
echo ""
echo "=================================================================="
echo " Marzban Node (JP) - DONE"
echo "   Next: re-run add-node-jp.sh on the MARZBAN box - it reconnects"
echo "   and prints the node status. 'connected' = success."
echo "   Logs if needed: docker logs gs-node --tail 30"
echo "=================================================================="
