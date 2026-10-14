#!/bin/bash
# ============================================================
# remove-argo-vmess.sh — Remove Cloudflare Argo Tunnel for VMess
#
# What it does:
#   1. Stops + disables the cloudflared-vmess service.
#   2. Deletes the Argo tunnel + its DNS route from Cloudflare.
#   3. Removes the VMess WS inbound (port 8081) from Xray config.
#   4. Restarts Xray. Existing inbounds (8080 TCP VMess, 8388 SS,
#      25574 VLESS) keep working.
#
# Usage:  sudo bash remove-argo-vmess.sh <subdomain> <domain>
# Example: sudo bash remove-argo-vmess.sh vmess musiczone.mobi
#
# NOTE: does NOT delete ~/.cloudflared/cert.pem (account login).
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash remove-argo-vmess.sh <subdomain> <domain>"
  exit 1
fi

SUB="${1:-}"
DOMAIN="${2:-}"
TUNNEL="goldensky-vmess"
WS_PORT=8081

if [ -z "$SUB" ] || [ -z "$DOMAIN" ]; then
  echo "Usage: sudo bash remove-argo-vmess.sh <subdomain> <domain>"
  echo "Example: sudo bash remove-argo-vmess.sh vmess musiczone.mobi"
  exit 1
fi

FULL_DOMAIN="${SUB}.${DOMAIN}"
XRAY_CFG="/usr/local/etc/xray/config.json"

echo "== 1/3 stop tunnel service =="
systemctl stop cloudflared-vmess 2>/dev/null || true
systemctl disable cloudflared-vmess 2>/dev/null || true
rm -f /etc/systemd/system/cloudflared-vmess.service
systemctl daemon-reload
echo "OK: cloudflared-vmess service removed."

echo "== 2/3 delete tunnel + DNS route =="
cloudflared tunnel route dns --delete "$TUNNEL" "$FULL_DOMAIN" 2>/dev/null || echo "(DNS route already gone)"
cloudflared tunnel delete "$TUNNEL" 2>/dev/null || echo "(tunnel already gone)"
rm -f "$HOME/.cloudflared/config.yml"
rm -f "$HOME/.cloudflared/${TUNNEL}"*.json
echo "OK: tunnel + DNS removed."

echo "== 3/3 remove VMess WS inbound (port $WS_PORT) =="
python3 - "$XRAY_CFG" "$WS_PORT" <<'PYEOF'
import json, sys
cfg_path, ws_port = sys.argv[1], int(sys.argv[2])
with open(cfg_path) as f:
    c = json.load(f)
before = len(c.get("inbounds", []))
c["inbounds"] = [ib for ib in c.get("inbounds", [])
                 if not (ib.get("port") == ws_port and ib.get("protocol") == "vmess")]
with open(cfg_path, "w") as f:
    json.dump(c, f, indent=2)
print(f"VMess WS inbound removed ({before} -> {len(c['inbounds'])} inbounds).")
PYEOF
xray -test -config "$XRAY_CFG" > /dev/null || { echo "ERROR: Xray config failed validation."; exit 1; }
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "ERROR: xray did not start."; exit 1; }
echo "OK: xray running without VMess WS."

echo ""
echo "DONE: Argo removed from this server."
