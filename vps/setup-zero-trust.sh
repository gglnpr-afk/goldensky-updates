#!/bin/bash
# ============================================================
# setup-zero-trust.sh — "Zero Trust Speed Bypass" one-shot setup
#
# What it does (all at once):
#   1. Adds a VLESS + WebSocket inbound to Xray
#      (listens on 127.0.0.1 only — no open ports needed)
#   2. Installs cloudflared and runs your Cloudflare Tunnel
#      with the token from your dashboard (no browser login)
#   3. Prints the ready-to-share vless:// "Speed Bypass" link
#
# Usage:  sudo bash setup-zero-trust.sh <TUNNEL_TOKEN> <DOMAIN> [WS_PATH] [PORT]
# Example: sudo bash setup-zero-trust.sh eyJh...I1NiIsIm... mm.zaw.my.id
#          (WS_PATH and PORT are auto-generated if omitted)
#
# After running, add ONE route in the Cloudflare dashboard
# (Zero Trust -> Networks -> Tunnels -> your tunnel
#  -> Public Hostname -> Add):
#    Hostname : <DOMAIN>
#    Service  : http://127.0.0.1:<PORT>
#
# ADDITIVE-ONLY: does not touch existing inbounds.
# Works on servers set up with setup-vps.sh (official Xray).
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash setup-zero-trust.sh <TUNNEL_TOKEN> <DOMAIN>"
  exit 1
fi

TOKEN="${1:-}"
DOMAIN="${2:-}"
WS_PATH="${3:-}"
PORT="${4:-3456}"

if [ -z "$TOKEN" ] || [ -z "$DOMAIN" ]; then
  echo "Usage: sudo bash setup-zero-trust.sh <TUNNEL_TOKEN> <DOMAIN> [WS_PATH] [PORT]"
  echo ""
  echo "  TUNNEL_TOKEN : Cloudflare dashboard -> Zero Trust -> Networks"
  echo "                 -> Tunnels -> your tunnel -> Configure -> Token"
  echo "  DOMAIN       : the hostname for Speed Bypass (e.g. mm.zaw.my.id)"
  exit 1
fi

# Auto-generate a safe ASCII path if none given
# (non-ASCII paths break on some client apps — always use ASCII)
if [ -z "$WS_PATH" ]; then
  WS_PATH="/$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_CFG="/usr/local/etc/xray/config.json"

echo "== 1/5 Xray check =="
if [ ! -f "$XRAY_CFG" ]; then
  echo "Installing Xray (official)..."
  bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version v25.9.11
fi
command -v xray > /dev/null || { echo "ERROR: xray install failed."; exit 1; }

echo "== 2/5 add VLESS WS inbound (127.0.0.1:$PORT, path $WS_PATH) =="
python3 - "$XRAY_CFG" "$UUID" "$PORT" "$WS_PATH" <<'PYEOF'
import json, sys
cfg_path, uuid, port, path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
try:
    with open(cfg_path) as f:
        c = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    c = {"log": {"loglevel": "warning"},
         "inbounds": [],
         "outbounds": [{"protocol": "freedom"}]}
for ib in c.get("inbounds", []):
    if ib.get("port") == port:
        print("Inbound on port %d already exists — keeping it." % port)
        sys.exit(0)
c.setdefault("inbounds", []).append({
    "listen": "127.0.0.1",
    "port": port,
    "protocol": "vless",
    "settings": {"clients": [{"id": uuid}], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": path}}
})
if not c.get("outbounds"):
    c["outbounds"] = [{"protocol": "freedom"}]
with open(cfg_path, "w") as f:
    json.dump(c, f, indent=2)
print("VLESS WS inbound added.")
PYEOF
xray -test -config "$XRAY_CFG" > /dev/null || { echo "ERROR: Xray config failed validation."; exit 1; }
systemctl restart xray 2>/dev/null || systemctl start xray
sleep 2
systemctl is-active --quiet xray || { echo "ERROR: xray did not start."; journalctl -u xray --no-pager -n 20; exit 1; }
echo "OK: xray running."

echo "== 3/5 install cloudflared =="
if ! command -v cloudflared > /dev/null 2>&1; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) CF_ARCH="amd64" ;;
    aarch64|arm64) CF_ARCH="arm64" ;;
    *) echo "ERROR: unsupported arch $ARCH"; exit 1 ;;
  esac
  curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi
echo "OK: $(cloudflared --version | head -1)"

echo "== 4/5 tunnel service (auto-restart) =="
cat > /etc/systemd/system/cloudflared-zt.service <<EOF
[Unit]
Description=Cloudflare Zero Trust Tunnel (Speed Bypass)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel run --token $TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
chmod 600 /etc/systemd/system/cloudflared-zt.service
systemctl daemon-reload
systemctl enable cloudflared-zt > /dev/null 2>&1
systemctl restart cloudflared-zt
sleep 4
systemctl is-active --quiet cloudflared-zt || { echo "ERROR: tunnel did not start. Check the token."; journalctl -u cloudflared-zt --no-pager -n 20; exit 1; }
echo "OK: tunnel connected."

echo "== 5/5 build Speed Bypass link =="
LINK=$(python3 - "$UUID" "$DOMAIN" "$WS_PATH" <<'PYEOF'
import sys, urllib.parse
uuid, domain, path = sys.argv[1], sys.argv[2], sys.argv[3]
enc_path = urllib.parse.quote(path, safe="/")
q = ("encryption=none&security=tls&sni=" + domain + "&fp=chrome"
     "&type=ws&host=" + domain + "&path=" + enc_path)
print("vless://%s@%s:443?%s#Zero-Trust-Speed-Bypass" % (uuid, domain, q))
PYEOF
)

echo ""
echo "==========================================================="
echo "DONE: Zero Trust Speed Bypass is ready"
echo ""
echo "Link:"
echo "$LINK"
echo ""
echo "Details:"
echo "  Domain : $DOMAIN"
echo "  UUID   : $UUID"
echo "  Path   : $WS_PATH"
echo ""
echo "LAST STEP (Cloudflare dashboard, one time):"
echo "  Zero Trust -> Networks -> Tunnels -> your tunnel"
echo "  -> Public Hostname -> Add"
echo "     Hostname : $DOMAIN"
echo "     Service  : http://127.0.0.1:$PORT"
echo "==========================================================="
