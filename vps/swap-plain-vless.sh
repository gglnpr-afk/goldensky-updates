#!/usr/bin/env bash
# GOLDENSKY Marzban swap: VLESS+REALITY -> PLAIN VLESS TCP (same port 443,
# same inbound tag, so every existing user/subscription keeps working),
# put a DOMAIN in all generated links instead of the raw IP, clear the
# xtls-rprx-vision flow from existing users, and patch the Telegram bot
# to create plain-VLESS users from now on.
#   sudo bash swap-plain-vless.sh [DOMAIN]   (default marz.gloriafreeproton.io)
set -euo pipefail
DOMAIN="${1:-marz.gloriafreeproton.io}"
TAG="VLESS TCP REALITY"
[ "$(id -u)" = "0" ] || { echo "Run as root: sudo bash swap-plain-vless.sh"; exit 1; }
[ -f /var/lib/marzban/xray_config.json ] || { echo "!! Marzban config not found. Run the Marzban kit first."; exit 1; }
[ -f /root/marzban-login.txt ] || { echo "!! /root/marzban-login.txt missing. Aborting."; exit 1; }

# ---------- 0. the domain must point at this box ----------
PUB_IP=$(curl -s -m 10 https://api.ipify.org || true)
PUB_IP=$(printf '%s' "$PUB_IP" | tr -dc '0-9.')
[ -n "$PUB_IP" ] || { echo "!! Could not detect public IP. Aborting."; exit 1; }
echo "-- public IP: $PUB_IP ; domain: $DOMAIN"
HIT=$(python3 - "$DOMAIN" "$PUB_IP" <<'PYEOF'
import sys, json, urllib.request
name, ip = sys.argv[1], sys.argv[2]
try:
    req = urllib.request.Request("https://dns.google/resolve?name=%s&type=A" % name,
                                 headers={"Accept": "application/dns-json"})
    d = json.load(urllib.request.urlopen(req, timeout=10))
    ips = [a["data"] for a in d.get("Answer", []) if a.get("type") == 1]
    print("MATCH" if ip in ips else "NOMATCH:" + ",".join(ips))
except Exception as e:
    print("ERROR:%s" % e)
PYEOF
) || HIT=""
case "$HIT" in
  MATCH) echo "   OK: $DOMAIN -> $PUB_IP" ;;
  *) echo "!! $DOMAIN does not resolve to this box ($HIT). Fix the A record first. Aborting."; exit 1 ;;
esac

# ---------- 1. swap the inbound to plain VLESS TCP ----------
BK="/var/lib/marzban/xray_config.json.bak-$(date +%s)"
cp -a /var/lib/marzban/xray_config.json "$BK"
echo "-- backup: $BK"
python3 - "$TAG" <<'PYEOF'
import json, sys
tag = sys.argv[1]
p = "/var/lib/marzban/xray_config.json"
cfg = json.load(open(p))
changed = False
for ib in cfg.get("inbounds", []):
    if ib.get("tag") == tag:
        ss = ib.get("streamSettings", {})
        if ss.get("security") == "reality" or "realitySettings" in ss:
            ib["streamSettings"] = {"network": "tcp", "security": "none"}
            changed = True
        break
else:
    print("!! inbound tag not found:", tag); sys.exit(1)
if changed:
    json.dump(cfg, open(p, "w"), indent=2)
    print("OK: inbound swapped to PLAIN VLESS TCP (port unchanged)")
else:
    print("OK: inbound already plain - nothing to swap")
PYEOF

# ---------- 2. restart Marzban ----------
echo "-- restarting Marzban..."
marzban restart -n >/dev/null 2>&1 || docker compose -f /opt/marzban/docker-compose.yml -p marzban up -d --force-recreate marzban >/dev/null 2>&1 || true
UP=0
for i in $(seq 1 30); do sleep 2; curl -s -m 3 -o /dev/null http://127.0.0.1:8000/ && { UP=1; break; }; done
[ "$UP" = "1" ] || { echo "!! Marzban did not come back on :8000. Check: docker ps / marzban status"; exit 1; }
echo "OK: Marzban is up"

# ---------- 3. API: domain in hosts, clear vision flow, verify ----------
ADMIN_PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
python3 - "$DOMAIN" "$ADMIN_PASS" <<'PYEOF'
import sys, json, urllib.request, urllib.parse, urllib.error
domain, pw = sys.argv[1], sys.argv[2]
base = "http://127.0.0.1:8000"

def req(method, path, data=None, tok=None, form=False):
    body = None; headers = {}
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    if tok: headers["Authorization"] = "Bearer " + tok
    r = urllib.request.Request(base + path, data=body, method=method, headers=headers)
    with urllib.request.urlopen(r, timeout=25) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else {}

tok = req("POST", "/api/admin/token", {"username": "admin", "password": pw}, form=True)["access_token"]

# hosts: set every host address to the domain (round-trip all other fields)
hosts = req("GET", "/api/hosts", tok=tok)
n = 0
for tag, lst in hosts.items():
    for h in lst:
        if h.get("address") != domain:
            h["address"] = domain; n += 1
if n:
    req("PUT", "/api/hosts", hosts, tok=tok)
print("OK: hosts updated to domain (%d changed)" % n)

# users: clear vless vision flow (PUT preserves all other settings/fields;
# Marzban DELETES proxy types missing from the PUT, so send them all back)
users = req("GET", "/api/users?offset=0&limit=1000", tok=tok).get("users", [])
fixed = 0
for u in users:
    proxies = u.get("proxies") or {}
    vl = proxies.get("vless") or {}
    if vl.get("flow"):
        new_proxies = dict(proxies)
        new_vless = {}
        if vl.get("id"): new_vless["id"] = vl["id"]
        new_proxies["vless"] = new_vless
        body = {"proxies": new_proxies,
                "expire": u.get("expire") or 0,
                "data_limit": u.get("data_limit") or 0,
                "data_limit_reset_strategy": u.get("data_limit_reset_strategy") or "no_reset"}
        if u.get("status") == "active":
            body["status"] = "active"
        req("PUT", "/api/user/" + u["username"], body, tok=tok)
        fixed += 1
print("OK: vision flow cleared for %d user(s)" % fixed)

# verify on test5gb (fallback: first user with a vless link)
probe = None
for name in ["test5gb"] + [u["username"] for u in users]:
    try:
        u = req("GET", "/api/user/" + name, tok=tok)
    except Exception:
        continue
    for lnk in u.get("links") or []:
        if lnk.startswith("vless://"):
            probe = (name, lnk); break
    if probe: break
if not probe:
    print("!! No VLESS link found to verify - check the panel manually"); sys.exit(1)
name, link = probe
assert "@" + domain + ":" in link, "domain missing from link: " + link
assert "reality" not in link and "pbk=" not in link, "link still REALITY: " + link
print("VERIFY OK: %s VLESS link is PLAIN and uses the domain" % name)
open("/tmp/plain-vless-link.txt", "w").write(link)
PYEOF

# ---------- 4. patch the Telegram bot (new users must be plain too) ----------
if [ -f /opt/gs-bot/bot.py ]; then
  if grep -q '"vless": {"flow": "xtls-rprx-vision"}' /opt/gs-bot/bot.py; then
    python3 - <<'PYEOF'
p = "/opt/gs-bot/bot.py"
s = open(p).read()
s = s.replace('"vless": {"flow": "xtls-rprx-vision"}', '"vless": {}')
open(p, "w").write(s)
print("OK: bot.py patched (plain VLESS for new claims)")
PYEOF
    python3 -m py_compile /opt/gs-bot/bot.py
    systemctl restart gs-tgbot
    sleep 3
    systemctl is-active --quiet gs-tgbot && echo "OK: gs-tgbot restarted" || echo "!! gs-tgbot not active - check: journalctl -u gs-tgbot -n 20"
  else
    echo "OK: bot.py already plain - no patch needed"
  fi
else
  echo "NOTE: Telegram bot not installed on this box - skipped bot patch"
fi

echo "=================================================================="
echo " PLAIN VLESS SWAP - DONE"
echo "   Domain : $DOMAIN (all links now use it, SS included)"
echo "   VLESS  : plain TCP on :443 (no REALITY) - same users, same quota"
echo "   Sample : $(cat /tmp/plain-vless-link.txt 2>/dev/null)"
echo "   Next   : in v2rayNG update subscriptions, or in the bot tap"
echo "            'My Key' to get fresh links. Old REALITY links are dead."
echo "=================================================================="
