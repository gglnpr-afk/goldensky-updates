#!/bin/bash
# ============================================================
# setup-argo-vmess.sh — Cloudflare Argo Tunnel for VMess (WS)
#
# What it does:
#   1. Adds a VMess + WebSocket inbound to Xray (port 8081, path /vmess)
#      using the SAME UUID as the existing VMess on 8080 — so the
#      same key works over Argo.
#   2. Installs cloudflared, creates a named Argo tunnel, and routes
#      https://<subdomain>.<domain> -> localhost:8081 (VMess WS).
#   3. Runs the tunnel as a systemd service (auto-restart).
#
# Usage:  sudo bash setup-argo-vmess.sh <subdomain> <domain>
# Example SG: sudo bash setup-argo-vmess.sh vmess musiczone.mobi
# Example JP: sudo bash setup-argo-vmess.sh vmess busterzone.mobi
# Result: VMess WS via https://vmess.musicone.mobi/vmess (port 443, TLS)
#
# NOTE: cloudflared login needs a browser ONCE. The script will print
# a Cloudflare URL — open it on your phone, approve, then press Enter.
#
# ADDITIVE-ONLY: does not touch existing inbounds (8080 TCP VMess,
# 8388 SS, 25574 VLESS all keep working). Safe to re-run.
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash setup-argo-vmess.sh <subdomain> <domain>"
  exit 1
fi

SUB="${1:-}"
DOMAIN="${2:-}"
TUNNEL="goldensky-vmess"
WS_PORT=8081
WS_PATH="/vmess"

if [ -z "$SUB" ] || [ -z "$DOMAIN" ]; then
  echo "Usage: sudo bash setup-argo-vmess.sh <subdomain> <domain>"
  echo "Example: sudo bash setup-argo-vmess.sh vmess musiczone.mobi"
  exit 1
fi

FULL_DOMAIN="${SUB}.${DOMAIN}"
XRAY_CFG="/usr/local/etc/xray/config.json"

echo "== 1/6 read existing VMess UUID (port 8080) =="
[ -f "$XRAY_CFG" ] || { echo "ERROR: $XRAY_CFG not found. Is Xray installed?"; exit 1; }
VMESS_UUID=$(python3 - "$XRAY_CFG" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
for ib in c.get("inbounds", []):
    if ib.get("port") == 8080 and ib.get("protocol") == "vmess":
        clients = ib.get("settings", {}).get("clients", [])
        if clients:
            print(clients[0]["id"])
            sys.exit(0)
sys.exit(1)
PYEOF
) || { echo "ERROR: no VMess inbound on port 8080 found."; exit 1; }
echo "VMess UUID: $VMESS_UUID"

echo "== 2/6 add VMess WS inbound (port $WS_PORT, path $WS_PATH) =="
python3 - "$XRAY_CFG" "$VMESS_UUID" "$WS_PORT" "$WS_PATH" <<'PYEOF'
import json, sys
cfg_path, uuid, ws_port, ws_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
with open(cfg_path) as f:
    c = json.load(f)
# Skip if already present (re-run safe)
for ib in c.get("inbounds", []):
    if ib.get("port") == ws_port and ib.get("protocol") == "vmess":
        print("VMess WS inbound already exists — keeping it.")
        sys.exit(0)
c.setdefault("inbounds", []).append({
    "port": ws_port,
    "protocol": "vmess",
    "settings": {"clients": [{"id": uuid, "alterId": 0}]},
    "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": ws_path}
    }
})
with open(cfg_path, "w") as f:
    json.dump(c, f, indent=2)
print("VMess WS inbound added.")
PYEOF
xray -test -config "$XRAY_CFG" > /dev/null || { echo "ERROR: Xray config failed validation."; exit 1; }
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "ERROR: xray did not start."; journalctl -u xray --no-pager -n 20; exit 1; }
echo "OK: xray running with VMess WS on $WS_PORT"

echo "== 3/6 install cloudflared =="
if ! command -v cloudflared > /dev/null 2>&1; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) CF_ARCH="amd64" ;;
    aarch64|arm64) CF_ARCH="arm64" ;;
    *) echo "ERROR: unsupported arch $ARCH"; exit 1 ;;
  esac
  curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
  echo "cloudflared installed."
else
  echo "cloudflared already installed: $(cloudflared --version | head -1)"
fi

echo "== 4/6 Cloudflare login (one-time) =="
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
  echo ""
  echo ">>> Open the URL below on your PHONE browser, log in to Cloudflare,"
  echo ">>> approve the tunnel, then come back here and press Enter."
  echo ""
  cloudflared tunnel login
  echo ""
  read -p "Press Enter after approving in the browser... "
fi
[ -f "$HOME/.cloudflared/cert.pem" ] || { echo "ERROR: login did not produce cert.pem"; exit 1; }
echo "OK: logged in to Cloudflare."

echo "== 5/6 create tunnel + DNS route =="
if ! cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL"; then
  cloudflared tunnel create "$TUNNEL"
  echo "Tunnel '$TUNNEL' created."
else
  echo "Tunnel '$TUNNEL' already exists — keeping it."
fi
mkdir -p "$HOME/.cloudflared"
cat > "$HOME/.cloudflared/config.yml" <<EOF
tunnel: $TUNNEL
credentials-file: $HOME/.cloudflared/${TUNNEL}.json
ingress:
  - hostname: $FULL_DOMAIN
    service: http://localhost:$WS_PORT
  - service: http_status:404
EOF
cloudflared tunnel route dns "$TUNNEL" "$FULL_DOMAIN" || echo "(DNS route may already exist — continuing)"
echo "OK: $FULL_DOMAIN -> localhost:$WS_PORT"

echo "== 6/6 tunnel service (auto-restart) =="
cat > /etc/systemd/system/cloudflared-vmess.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel for VMess WS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config $HOME/.cloudflared/config.yml run $TUNNEL
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cloudflared-vmess > /dev/null 2>&1
systemctl restart cloudflared-vmess
sleep 3
systemctl is-active --quiet cloudflared-vmess || { echo "ERROR: tunnel did not start."; journalctl -u cloudflared-vmess --no-pager -n 20; exit 1; }

echo ""
echo "==========================================================="
echo "DONE: Argo VMess is live"
echo "Domain : https://$FULL_DOMAIN$WS_PATH"
echo "VMess  : address=$FULL_DOMAIN port=443 net=ws path=$WS_PATH tls=tls"
echo "UUID   : $VMESS_UUID"
echo "==========================================================="
echo ""
echo "Send the domain + UUID above to get the new VMess key."
