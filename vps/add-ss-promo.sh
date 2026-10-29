#!/usr/bin/env bash
# add-ss-promo.sh — GOLDENSKY kit: free PROMO Shadowsocks key with a hard
# data quota (300 GiB total pool) on an existing kit Xray server.
#
# What it does (all additive, existing inbounds/customers untouched):
# - Adds ONE new SS inbound on port 8390 (tag "ss-promo", aes-128-gcm)
#   with a single client whose email is "promo300" (traffic identity).
# - Enables Xray per-user traffic stats (stats + StatsService API on
#   127.0.0.1:10085, localhost only + policy flags) — only blocks that
#   are missing are added.
# - Installs gs-promo-guard.sh (cron, every 5 min): accumulates the
#   promo client's traffic across restarts and REMOVES the client when
#   the 300 GiB pool is used up. Usage anytime: cat /root/ss-promo-usage.txt
# - Config is backed up first; `xray -test` must pass before restart;
#   on any failure the backup is restored and nothing changes.
#
# RE-RUNNING = RENEW: fresh password, usage counter reset, key re-armed.
# The old printed link dies the moment you re-run.
#
# Lightsail CONSOLE: open TCP 8390 AND UDP 8390 (Networking -> Firewall)
# or the key will time out from phones.
#
# Usage:  sudo bash add-ss-promo.sh
set -uo pipefail

CFG="/usr/local/etc/xray/config.json"
XRAY="/usr/local/bin/xray"
PORT=8390
TAG="ss-promo"
EMAIL="promo300"
METHOD="aes-128-gcm"
API_PORT=10085
DOMAIN="donatekey.realty"
GUARD_URL="https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/gs-promo-guard.sh"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
[ -f "$CFG" ] || { echo "Xray config not found: $CFG"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
if ss -tln 2>/dev/null | grep -q ":$PORT " && ! grep -q "\"$TAG\"" "$CFG"; then
  echo "Port $PORT is used by something else — aborting."; exit 1
fi

PASS="$(openssl rand -base64 16)"
BAK="$CFG.bak.promo-$(date +%s)"
cp "$CFG" "$BAK"
echo "Config backed up: $BAK"

PASS="$PASS" PORT="$PORT" TAG="$TAG" EMAIL="$EMAIL" METHOD="$METHOD" API_PORT="$API_PORT" CFG="$CFG" python3 - <<'PYEOF'
import json, os
cfg = json.load(open(os.environ["CFG"]))
port, tag, email = int(os.environ["PORT"]), os.environ["TAG"], os.environ["EMAIL"]
method, apip = os.environ["METHOD"], int(os.environ["API_PORT"])

# --- stats plumbing (add only what is missing) ---
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

# --- promo inbound (replace on re-run = renew with a fresh password) ---
ib[:] = [i for i in ib if i.get("tag") != tag]
ib.append({
    "tag": tag, "port": port, "protocol": "shadowsocks",
    "settings": {"method": method, "network": "tcp,udp",
                 "clients": [{"method": method, "password": os.environ["PASS"],
                              "email": email, "level": 0}]},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
})
json.dump(cfg, open(os.environ["CFG"], "w"), indent=2)
print("Config updated: stats on, promo inbound on port", port)
PYEOF

if ! "$XRAY" -test -config "$CFG" >/dev/null 2>&1; then
  echo "xray -test FAILED — restoring backup, nothing changed."
  cp "$BAK" "$CFG"; exit 1
fi
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
  echo "xray did not start — restoring backup."
  cp "$BAK" "$CFG"; systemctl restart xray; exit 1
fi

# --- guard: prefer a copy beside this script, else fetch from GitHub ---
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

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow ${PORT}/tcp >/dev/null; ufw allow ${PORT}/udp >/dev/null
  echo "ufw: opened $PORT tcp+udp"
fi

USERINFO="$(printf '%s' "${METHOD}:${PASS}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
LINK="ss://${USERINFO}@${DOMAIN}:${PORT}#GOLDENSKY-SG-FREE-300GB"
{
  echo "$LINK"
  echo "Quota: 300 GiB total pool (auto-disables when used up)"
  echo "Usage check: cat /root/ss-promo-usage.txt"
} > /root/my-ss-promo.txt

echo
echo "=== PROMO SS KEY LIVE (300 GiB pool) ==="
echo "$LINK"
echo
echo "Usage anytime:  cat /root/ss-promo-usage.txt"
echo "Renew later:    re-run this script (new link, counter reset)"
echo "REMINDER: Lightsail console must have TCP $PORT + UDP $PORT open."
