#!/usr/bin/env bash
# add-ss-promo-fresh.sh — GOLDENSKY: the SG-style FREE promo SS key
# (300 GiB shared pool, auto-off) for a box WITHOUT a kit Xray install —
# e.g. the FirstByte JP box that only carries the 3x-ui panel.
#
# What it does (all additive, panel untouched):
#   1. If no standalone Xray exists, installs it (official installer via
#      jsDelivr mirror) and writes a minimal base config if none exists.
#      The standalone Xray runs BESIDE the panel's own Xray; ports differ
#      (promo 8390, stats API 127.0.0.1:10085) so nothing clashes.
#   2. Adds the stats plumbing (only what's missing) + the ss-promo
#      inbound on :8390 with ONE client (email "promo300").
#   3. Installs gs-promo-guard.sh + cron: at >= 300 GiB the client is
#      removed automatically. Usage: cat /root/ss-promo-usage.txt
#   4. Prints the ss:// link (host = this box's public IP by default;
#      override with PROMO_HOST=<domain>).
# Re-running = RENEW: fresh password, counter reset, old link dies.
set -uo pipefail

CFG="/usr/local/etc/xray/config.json"
XRAY="/usr/local/bin/xray"
PORT=8390
TAG="ss-promo"
EMAIL="promo300"
METHOD="aes-128-gcm"
API_PORT=10085
HOST="${PROMO_HOST:-132.243.30.145}"
GUARD_URL="https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/gs-promo-guard.sh"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }

# --- 1. standalone Xray + base config --------------------------------
if [ ! -x "$XRAY" ]; then
  echo "Installing standalone Xray..."
  curl -sL https://cdn.jsdelivr.net/gh/XTLS/Xray-install@main/install-release.sh -o /tmp/xray-install.sh
  bash /tmp/xray-install.sh install || { echo "Xray install failed."; exit 1; }
fi
[ -x "$XRAY" ] || { echo "Xray binary still missing — aborting."; exit 1; }
mkdir -p "$(dirname "$CFG")"
if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {"rules": []}
}
JSON
  echo "Base config written: $CFG"
fi
if ! systemctl cat xray >/dev/null 2>&1; then
  cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
fi

BAK="$CFG.bak.promo-$(date +%s)"
cp "$CFG" "$BAK"
echo "Config backed up: $BAK"

# --- 2. stats plumbing + promo inbound --------------------------------
PASS="$(openssl rand -base64 16)"
PASS="$PASS" PORT="$PORT" TAG="$TAG" EMAIL="$EMAIL" METHOD="$METHOD" API_PORT="$API_PORT" CFG="$CFG" python3 - <<'PYEOF'
import json, os
cfg = json.load(open(os.environ["CFG"]))
port, tag, email = int(os.environ["PORT"]), os.environ["TAG"], os.environ["EMAIL"]
method, apip = os.environ["METHOD"], int(os.environ["API_PORT"])

cfg.setdefault("stats", {})
api = cfg.setdefault("api", {})
api.setdefault("tag", "api")
svcs = api.setdefault("services", [])
if "StatsService" not in svcs: svcs.append("StatsService")
pol = cfg.setdefault("policy", {})
lvl = pol.setdefault("levels", {}).setdefault("0", {})
lvl["statsUserUplink"] = True
lvl["statsUserDownlink"] = True
ib = cfg.setdefault("inbounds", [])
if not any(i.get("tag") == "api" for i in ib):
    ib.append({"listen": "127.0.0.1", "port": apip, "protocol": "dokodemo-door",
               "settings": {"address": "127.0.0.1"}, "tag": "api"})
rt = cfg.setdefault("routing", {})
rules = rt.setdefault("rules", [])
if not any(r.get("outboundTag") == "api" for r in rules):
    rules.append({"type": "field", "inboundTag": ["api"], "outboundTag": "api"})

clients = [{"method": method, "password": os.environ["PASS"], "email": email, "level": 0}]
promo = next((i for i in ib if i.get("tag") == tag), None)
if promo is None:
    ib.append({"tag": tag, "port": port, "protocol": "shadowsocks",
               "settings": {"method": method, "network": "tcp,udp", "clients": clients},
               "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}})
else:
    promo["port"] = port
    promo.setdefault("settings", {})["clients"] = clients
json.dump(cfg, open(os.environ["CFG"], "w"), indent=2)
print("Config updated: stats on, promo inbound on port", port)
PYEOF

if ! "$XRAY" -test -config "$CFG" >/dev/null 2>&1; then
  echo "xray -test FAILED — restoring backup, nothing changed."
  cp "$BAK" "$CFG"; exit 1
fi
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
  echo "xray did not start — restoring backup."
  cp "$BAK" "$CFG"; systemctl restart xray; exit 1
fi

# --- 3. guard + usage state -------------------------------------------
if [ -f "$HERE/gs-promo-guard.sh" ]; then
  cp "$HERE/gs-promo-guard.sh" /usr/local/bin/gs-promo-guard.sh
else
  curl -sL "$GUARD_URL" -o /usr/local/bin/gs-promo-guard.sh || { echo "Guard download failed."; exit 1; }
fi
chmod +x /usr/local/bin/gs-promo-guard.sh
echo '*/5 * * * * root /usr/local/bin/gs-promo-guard.sh >/dev/null 2>&1' > /etc/cron.d/gs-promo-guard
mkdir -p /var/lib/gs-promo
echo 0 > /var/lib/gs-promo/state.txt
rm -f /var/lib/gs-promo/disabled
/usr/local/bin/gs-promo-guard.sh || true

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
fi

# --- 4. the link -------------------------------------------------------
USERINFO="$(printf '%s' "${METHOD}:${PASS}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
LINK="ss://${USERINFO}@${HOST}:${PORT}#GOLDENSKY-JP-FREE-300GB"
echo "$LINK" > /root/my-ss-promo.txt

echo
echo "=== PROMO SS KEY LIVE (300 GiB pool) ==="
echo "$LINK"
echo
echo "Check usage anytime:  cat /root/ss-promo-usage.txt"
echo "Renew (new password + counter reset): re-run this script."
