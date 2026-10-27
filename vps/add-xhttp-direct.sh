#!/usr/bin/env bash
# add-xhttp-direct.sh — GOLDENSKY kit: add a TEST-ONLY VLESS + XHTTP inbound
# reachable DIRECTLY on the server's public IP (NO Cloudflare Tunnel, NO TLS)
# to an EXISTING Xray install. Purpose: bisect whether the GOLDENSKY XHTTP
# failure lives on the app<->Cloudflare-edge leg or inside the app itself —
# the same packet-up profile, minus the tunnel, is tested against this
# inbound.
#
# *** TEST-ONLY — READ BEFORE RUNNING ***
# This inbound is PLAIN HTTP: the transport is UNENCRYPTED and visible on
# the wire (the VLESS payload rides inside, but the outer XHTTP stream has
# no TLS). Do NOT leave it running. Remove it after testing by restoring
# the timestamped backup this script prints (or deleting the
# "vless-xhttp-direct" inbound from the config) and restarting xray.
#
# Additive like add-xhttp.sh: backs up the config, appends ONE inbound
# (0.0.0.0:3458, path /xhttp), validates with `xray -test`, restarts xray
# ONLY if the test passes, restores the backup on failure, and prints a
# ready-to-import vless:// test link (also saved to
# /root/my-xhttp-direct.txt). If port 3458 is already in the config it
# ABORTS instead of duplicating. Re-running after removal rotates the UUID.
#
# Usage:  sudo bash add-xhttp-direct.sh
set -uo pipefail

CFG=/usr/local/etc/xray/config.json
PORT=3458
XPATH=/xhttp
TAG=vless-xhttp-direct
PUBIP=46.8.125.49

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
if [ ! -f "$CFG" ]; then echo "Xray config not found: $CFG"; exit 1; fi
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }

# Idempotent-safe: abort if any inbound already uses port 3458.
PORT="$PORT" python3 - <<'PYEOF'
import json, os, sys
cfg = json.load(open("/usr/local/etc/xray/config.json"))
port = int(os.environ["PORT"])
if any(ib.get("port") == port for ib in cfg.get("inbounds", [])):
    print("Port %d is already present in the config — aborting." % port)
    print("Remove that inbound (or restore a backup) before re-running.")
    sys.exit(1)
PYEOF
[ $? -ne 0 ] && exit 1

UUID=$(cat /proc/sys/kernel/random/uuid)
BAK="$CFG.bak.$(date +%s)"
cp "$CFG" "$BAK"
echo "Backup: $BAK"

UUID="$UUID" PORT="$PORT" XPATH="$XPATH" TAG="$TAG" python3 - <<'PYEOF'
import json, os
cfg_path = "/usr/local/etc/xray/config.json"
cfg = json.load(open(cfg_path))
inbounds = cfg.setdefault("inbounds", [])
inbounds.append({
    "tag": os.environ["TAG"],
    "listen": "0.0.0.0",
    "port": int(os.environ["PORT"]),
    "protocol": "vless",
    "settings": {
        "clients": [{"id": os.environ["UUID"], "flow": ""}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {"path": os.environ["XPATH"], "mode": "packet-up"}
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
})
json.dump(cfg, open(cfg_path, "w"), indent=2)
print("inbound added: vless + xhttp on 0.0.0.0:%s path %s" % (os.environ["PORT"], os.environ["XPATH"]))
PYEOF
if [ $? -ne 0 ]; then
  echo "Config edit failed — restoring backup."
  cp "$BAK" "$CFG"
  exit 1
fi

if ! xray -test -c "$CFG" >/dev/null 2>&1; then
  echo "xray -test FAILED — restoring backup."
  cp "$BAK" "$CFG"
  exit 1
fi

# Open the firewall only when ufw is present and active.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
  ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
  echo "ufw: allowed ${PORT}/tcp"
fi

systemctl restart xray 2>/dev/null || service xray restart
sleep 1
systemctl is-active xray >/dev/null 2>&1 && echo "xray: running" || echo "WARN: xray not active — check: journalctl -u xray -n 30"

LINK="vless://${UUID}@${PUBIP}:${PORT}?encryption=none&security=none&type=xhttp&host=${PUBIP}&path=${XPATH}&mode=packet-up#GS-XHTTP-DIRECT-TEST"
echo "$LINK" > /root/my-xhttp-direct.txt

echo
echo "================ XHTTP DIRECT TEST LINK ================"
echo "$LINK"
echo "=========================================================="
echo "(also saved to /root/my-xhttp-direct.txt)"
echo "TEST-ONLY — remove after testing: restore $BAK (or delete inbound '$TAG') and restart xray."
