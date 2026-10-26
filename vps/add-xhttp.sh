#!/usr/bin/env bash
# add-xhttp.sh — GOLDENSKY kit: add a VLESS + XHTTP inbound (localhost only,
# for a Cloudflare Tunnel route) to an EXISTING Xray install.
#
# Additive like add-ss.sh: backs up the config, appends ONE inbound
# (127.0.0.1:3457, path /xhttp), validates with `xray -test`, restarts xray,
# and prints a ready-to-import vless:// link for the Cloudflare hostname.
# Re-running rotates the client UUID (old link dies).
#
# Usage:  sudo bash add-xhttp.sh [HOSTNAME]
#         HOSTNAME defaults to xh.chithinphyu.info
set -uo pipefail

HOSTNAME="${1:-xh.chithinphyu.info}"
CFG=/usr/local/etc/xray/config.json
PORT=3457
XPATH=/xhttp
TAG=vless-xhttp

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
if [ ! -f "$CFG" ]; then echo "Xray config not found: $CFG"; exit 1; fi
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }

UUID=$(cat /proc/sys/kernel/random/uuid)
cp "$CFG" "$CFG.bak.$(date +%s)"

UUID="$UUID" PORT="$PORT" XPATH="$XPATH" TAG="$TAG" python3 - <<'PYEOF'
import json, os, sys
cfg_path = "/usr/local/etc/xray/config.json"
cfg = json.load(open(cfg_path))
inbounds = cfg.setdefault("inbounds", [])
# Drop a previous copy of this inbound (re-run = rotate UUID).
inbounds[:] = [ib for ib in inbounds if ib.get("tag") != os.environ["TAG"]]
inbounds.append({
    "tag": os.environ["TAG"],
    "listen": "127.0.0.1",
    "port": int(os.environ["PORT"]),
    "protocol": "vless",
    "settings": {
        "clients": [{"id": os.environ["UUID"], "flow": ""}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": os.environ["XPATH"]}
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
})
json.dump(cfg, open(cfg_path, "w"), indent=2)
print("inbound added: vless + xhttp on 127.0.0.1:%s path %s" % (os.environ["PORT"], os.environ["XPATH"]))
PYEOF
[ $? -ne 0 ] && { echo "Config edit failed — backup kept."; exit 1; }

if ! xray -test -c "$CFG" >/dev/null 2>&1; then
  echo "xray -test FAILED — restoring backup."
  cp "$(ls -t $CFG.bak.* | head -1)" "$CFG"
  exit 1
fi

systemctl restart xray 2>/dev/null || service xray restart
sleep 1
systemctl is-active xray >/dev/null 2>&1 && echo "xray: running" || echo "WARN: xray not active — check: journalctl -u xray -n 30"

echo
echo "================ XHTTP LINK ================"
echo "vless://${UUID}@${HOSTNAME}:443?encryption=none&security=tls&sni=${HOSTNAME}&fp=chrome&type=xhttp&host=${HOSTNAME}&path=${XPATH}&alpn=h2#GOLDENSKY-SG2-XHTTP"
echo "============================================"
echo "Cloudflare route needed: ${HOSTNAME}  ->  http://127.0.0.1:${PORT}"
