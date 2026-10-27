#!/usr/bin/env bash
# add-xhttp-direct2.sh — GOLDENSKY kit: add a TEST-ONLY VLESS + XHTTP + TLS
# inbound reachable DIRECTLY on the server's public IP (NO Cloudflare
# Tunnel) to an EXISTING Xray install. Purpose: bisect whether the
# GOLDENSKY XHTTP failure lives on the app<->Cloudflare-edge leg or inside
# the app itself — the same packet-up profile, minus the tunnel, is tested
# against this inbound.
#
# v2 of add-xhttp-direct.sh: v1 used security=none, but Xray-core 26.x
# REFUSES to start a VLESS inbound without TLS when the address is a
# public (non-private) IP ("vless without TLS or other encryption is
# prohibited unless the server address is a private IP or domain") — the
# phone test failed at core start. v2 therefore terminates TLS on the
# server with a SELF-SIGNED certificate (generated on first run, reused
# after). The client link carries allowInsecure=1, so the self-signed cert
# is accepted for this test. The certificate is NOT a real identity check
# — fine for a bisection test, NOT for production use.
#
# *** TEST-ONLY — READ BEFORE RUNNING ***
# Do NOT leave this inbound running. Remove it after testing by restoring
# the timestamped backup this script prints (or deleting the
# "vless-xhttp-direct2" inbound from the config) and restarting xray.
# The self-signed cert/key at /usr/local/etc/xray/direct-test.{crt,key}
# can be deleted too.
#
# Additive like add-xhttp.sh: backs up the config, appends ONE inbound
# (0.0.0.0:3459, path /xhttp, mode packet-up), validates with `xray -test`,
# restarts xray ONLY if the test passes, restores the backup on failure,
# and prints a ready-to-import vless:// test link (also saved to
# /root/my-xhttp-direct2.txt). If port 3459 is already in the config it
# ABORTS instead of duplicating. Re-running after removal rotates the UUID.
#
# Usage:  sudo bash add-xhttp-direct2.sh
set -uo pipefail

CFG=/usr/local/etc/xray/config.json
PORT=3459
XPATH=/xhttp
TAG=vless-xhttp-direct2
PUBIP=46.8.125.49
CERT=/usr/local/etc/xray/direct-test.crt
KEY=/usr/local/etc/xray/direct-test.key

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
if [ ! -f "$CFG" ]; then echo "Xray config not found: $CFG"; exit 1; fi
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
command -v openssl >/dev/null || { echo "openssl missing"; exit 1; }

# Idempotent-safe: abort if any inbound already uses port 3459.
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

# Self-signed test certificate (CN + SAN = the server's public IP).
# Generated once; reused on later runs if both files already exist.
if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  echo "cert: reusing existing $CERT"
else
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=${PUBIP}" -addext "subjectAltName=IP:${PUBIP}" >/dev/null 2>&1
  if [ $? -ne 0 ]; then echo "openssl cert generation FAILED — aborting."; exit 1; fi
  chmod 600 "$KEY"
  echo "cert: generated self-signed $CERT (CN=${PUBIP}, SAN IP:${PUBIP}, 365 days)"
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
BAK="$CFG.bak.$(date +%s)"
cp "$CFG" "$BAK"
echo "Backup: $BAK"

UUID="$UUID" PORT="$PORT" XPATH="$XPATH" TAG="$TAG" CERT="$CERT" KEY="$KEY" python3 - <<'PYEOF'
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
        "security": "tls",
        "tlsSettings": {
            "certificates": [{
                "certificateFile": os.environ["CERT"],
                "keyFile": os.environ["KEY"]
            }]
        },
        "xhttpSettings": {"path": os.environ["XPATH"], "mode": "packet-up"}
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
})
json.dump(cfg, open(cfg_path, "w"), indent=2)
print("inbound added: vless + xhttp + tls (self-signed) on 0.0.0.0:%s path %s" % (os.environ["PORT"], os.environ["XPATH"]))
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

LINK="vless://${UUID}@${PUBIP}:${PORT}?encryption=none&security=tls&sni=${PUBIP}&fp=chrome&allowInsecure=1&type=xhttp&host=${PUBIP}&path=${XPATH}&mode=packet-up#GS-XHTTP-DIRECT2"
echo "$LINK" > /root/my-xhttp-direct2.txt

echo
echo "================ XHTTP DIRECT TLS TEST LINK ================"
echo "$LINK"
echo "=============================================================="
echo "(also saved to /root/my-xhttp-direct2.txt)"
echo "TEST-ONLY — remove after testing: restore $BAK (or delete inbound '$TAG') and restart xray."
