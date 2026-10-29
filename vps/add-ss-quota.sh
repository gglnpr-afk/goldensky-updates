#!/usr/bin/env bash
# add-ss-quota.sh — GOLDENSKY kit: mint ONE paid Shadowsocks key with a
# GB quota + day limit on an existing kit Xray server (the "shop" line).
#
#   sudo bash add-ss-quota.sh <customer-name> [GB] [days]
#   e.g.  sudo bash add-ss-quota.sh ko-aung        -> 100 GB, 30 days
#         sudo bash add-ss-quota.sh may-thu 50 30  -> 50 GB, 30 days
#
# - Keys live in a dedicated SS inbound: tag "ss-shop", port 8391,
#   aes-128-gcm, one client per customer (email "q-<name>").
# - Enforcement is by gs-quota-guard.sh (installed on first run, cron
#   every 5 min): the client is auto-removed when the GB quota is used
#   up OR the days run out, whichever comes first.
# - Registry: /root/quota-users.txt   Status: /root/quota-status.txt
# - Additive + safe: stats plumbing is added only if missing, config is
#   backed up, `xray -test` must pass before restart, restore on failure.
# - A duplicate customer name is REFUSED (delete the old line from
#   /root/quota-users.txt first if you really want to re-issue).
#
# The promo key (add-ss-promo.sh, port 8390) and all existing inbounds
# are untouched by this script.
set -uo pipefail

CFG="/usr/local/etc/xray/config.json"
XRAY="/usr/local/bin/xray"
PORT=8391
TAG="ss-shop"
METHOD="aes-128-gcm"
API_PORT=10085
DOMAIN="donatekey.realty"
REG="/root/quota-users.txt"
GUARD_URL="https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/gs-quota-guard.sh"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

NAME="${1:-}"
GB="${2:-100}"
DAYS="${3:-30}"
if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
[ -n "$NAME" ] || { echo "Usage: sudo bash add-ss-quota.sh <customer-name> [GB] [days]"; exit 1; }
[ -f "$CFG" ] || { echo "Xray config not found: $CFG"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
case "$GB$DAYS" in *[!0-9]*) echo "GB and days must be numbers."; exit 1 ;; esac
EMAIL="q-$(echo "$NAME" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9._-')"
if grep -qP "^[^\t]*\t${EMAIL}\t" "$REG" 2>/dev/null; then
  echo "Customer '$NAME' ($EMAIL) already has a key — refused."
  echo "Status: cat /root/quota-status.txt"
  exit 1
fi

PASS="$(openssl rand -base64 16)"
QUOTA_BYTES=$(( GB * 1073741824 ))
EXPIRY=$(( $(date +%s) + DAYS * 86400 ))
BAK="$CFG.bak.quota-$(date +%s)"
cp "$CFG" "$BAK"
echo "Config backed up: $BAK"

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

shop = next((i for i in ib if i.get("tag") == tag), None)
if shop is None:
    shop = {"tag": tag, "port": port, "protocol": "shadowsocks",
            "settings": {"method": method, "network": "tcp,udp", "clients": []},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}}
    ib.append(shop)
clients = shop.setdefault("settings", {}).setdefault("clients", [])
clients[:] = [c for c in clients if c.get("email") != email]
clients.append({"method": method, "password": os.environ["PASS"], "email": email, "level": 0})
json.dump(cfg, open(os.environ["CFG"], "w"), indent=2)
print("Customer added to", tag, "on port", port)
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

# Guard install (first run) + cron.
if [ ! -f /usr/local/bin/gs-quota-guard.sh ]; then
  if [ -f "$HERE/gs-quota-guard.sh" ]; then
    cp "$HERE/gs-quota-guard.sh" /usr/local/bin/gs-quota-guard.sh
  else
    curl -sL "$GUARD_URL" -o /usr/local/bin/gs-quota-guard.sh || { echo "Guard download failed."; exit 1; }
  fi
  chmod +x /usr/local/bin/gs-quota-guard.sh
fi
echo '*/5 * * * * root /usr/local/bin/gs-quota-guard.sh >/dev/null 2>&1' > /etc/cron.d/gs-quota-guard

touch "$REG"
printf '%s\t%s\t%s\t%s\t%s\n' "$NAME" "$EMAIL" "$QUOTA_BYTES" "$EXPIRY" "$PASS" >> "$REG"
mkdir -p /var/lib/gs-quota
echo 0 > "/var/lib/gs-quota/$EMAIL.bytes"
rm -f "/var/lib/gs-quota/$EMAIL.disabled"
/usr/local/bin/gs-quota-guard.sh || true

USERINFO="$(printf '%s' "${METHOD}:${PASS}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
LINK="ss://${USERINFO}@${DOMAIN}:${PORT}#GOLDENSKY-${NAME}-${GB}GB"
echo "$LINK" >> /root/my-shop-keys.txt

echo
echo "=== KEY MINTED: $NAME — $GB GB / $DAYS days ==="
echo "$LINK"
echo
echo "Expires: $(date -d "@$EXPIRY" +%Y-%m-%d)"
echo "All keys + usage:  cat /root/quota-status.txt"
