#!/usr/bin/env bash
# GS-SET-KEY-GB - change the Telegram bot's key size (GB per day).
# Updates bot.env (KEY_GB), the bot's on-screen texts, restarts the bot,
# and raises the data_limit of ALL existing tg_* users in Marzban.
#   sudo bash set-key-gb.sh [GB]     (default 50)
set -euo pipefail
GB="${1:-50}"
case "$GB" in *[!0-9]*|"") echo "GB must be a whole number, e.g.: sudo bash set-key-gb.sh 50"; exit 1 ;; esac
[ "$(id -u)" = "0" ] || { echo "Run as root: sudo bash set-key-gb.sh"; exit 1; }
[ -f /opt/gs-bot/bot.env ] || { echo "!! Telegram bot not installed on this box. Aborting."; exit 1; }
[ -f /root/marzban-login.txt ] || { echo "!! /root/marzban-login.txt missing. Aborting."; exit 1; }
BYTES=$((GB * 1024 * 1024 * 1024))

# ---------- 1. bot.env ----------
if grep -q '^KEY_GB=' /opt/gs-bot/bot.env; then
  sed -i "s/^KEY_GB=.*/KEY_GB=$GB/" /opt/gs-bot/bot.env
else
  echo "KEY_GB=$GB" >> /opt/gs-bot/bot.env
fi
echo "OK: bot.env KEY_GB=$GB"

# ---------- 2. bot texts (button / welcome / prompts) ----------
python3 - "$GB" <<'PYEOF'
import re, sys
gb = sys.argv[1]
p = "/opt/gs-bot/bot.py"
s = open(p).read()
s2 = re.sub(r"\d+GB", gb + "GB", s)
if s2 != s:
    open(p, "w").write(s2)
    print("OK: bot texts now say %sGB" % gb)
else:
    print("OK: bot texts already say %sGB" % gb)
PYEOF
python3 -m py_compile /opt/gs-bot/bot.py
systemctl restart gs-tgbot
sleep 3
systemctl is-active --quiet gs-tgbot && echo "OK: gs-tgbot restarted" || { echo "!! gs-tgbot not active - check: journalctl -u gs-tgbot -n 20"; exit 1; }

# ---------- 3. existing tg_* users -> new data_limit ----------
ADMIN_PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
python3 - "$BYTES" "$ADMIN_PASS" <<'PYEOF'
import sys, json, urllib.request, urllib.parse
nbytes, pw = int(sys.argv[1]), sys.argv[2]
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
users = req("GET", "/api/users?offset=0&limit=1000", tok=tok).get("users", [])
n = 0
for u in users:
    if u["username"].startswith("tg_") and (u.get("data_limit") or 0) != nbytes:
        req("PUT", "/api/user/" + u["username"], {"data_limit": nbytes}, tok=tok)
        n += 1
print("OK: %d existing bot user(s) raised to the new limit" % n)
PYEOF

echo "=================================================================="
echo " KEY SIZE CHANGED - DONE"
echo "   Bot keys are now ${GB}GB per day (daily reset, same as before)"
echo "   New claims AND existing bot users both get ${GB}GB/day"
echo "   NOTE: the bot's Telegram NAME still says 5GB - rename it in"
echo "   @BotFather with /setname if you want it to match."
echo "   Panel test users (test5gb / burn100mb) were NOT touched."
echo "=================================================================="
