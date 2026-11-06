#!/usr/bin/env bash
# GOLDENSKY Telegram Bot installer - issues 5GB/day keys from the Marzban
# panel installed by setup-marzban-test.sh on THIS box.
#   sudo bash setup-tgbot.sh
# The BotFather token is prompted for INSIDE this terminal (never leaves
# the box). Re-running updates the bot code and restarts the service.
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "Run as root: sudo bash setup-tgbot.sh"; exit 1; }
[ -f /opt/marzban/.env ] || { echo "!! Marzban not found on this box. Run the Marzban kit first."; exit 1; }
[ -f /root/marzban-login.txt ] || { echo "!! /root/marzban-login.txt missing (Marzban kit creates it). Aborting."; exit 1; }

DOMAIN="marz.gloriafreeproton.io"
mkdir -p /opt/gs-bot

# ---------- bot code ----------
cat > /opt/gs-bot/bot.py <<'BOTPYEOF'
#!/usr/bin/env python3
# GOLDENSKY Telegram bot - issues 5GB/day Marzban keys.
# Stdlib only (works on AlmaLinux python3.6+). Config: /opt/gs-bot/bot.env
import json, os, sys, time, html, urllib.request, urllib.parse, urllib.error

ENV_PATH = "/opt/gs-bot/bot.env"
STATE_PATH = "/opt/gs-bot/state.json"

def load_env(path):
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg

CFG = load_env(ENV_PATH)
BOT_TOKEN = CFG["BOT_TOKEN"]
MZ_BASE = CFG.get("MZ_BASE", "http://127.0.0.1:8000").rstrip("/")
MZ_USER = CFG.get("MZ_USER", "admin")
MZ_PASS = CFG["MZ_PASS"]
PUBLIC_BASE = CFG.get("PUBLIC_BASE", "").rstrip("/")
KEY_GB = int(CFG.get("KEY_GB", "5"))
KEY_DAYS = int(CFG.get("KEY_DAYS", "30"))
TG = "https://api.telegram.org/bot" + BOT_TOKEN

# ---------------- Telegram helpers ----------------
def tg_call(method, payload, timeout=40):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(TG + "/" + method, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def send(chat_id, text, buttons=None):
    p = {"chat_id": chat_id, "text": text, "parse_mode": "HTML",
         "disable_web_page_preview": True}
    if buttons:
        p["reply_markup"] = {"inline_keyboard": buttons}
    try:
        tg_call("sendMessage", p, timeout=15)
    except Exception as e:
        print("sendMessage failed:", e, file=sys.stderr)

def answer_cb(cb_id, text=""):
    try:
        tg_call("answerCallbackQuery", {"callback_query_id": cb_id, "text": text}, timeout=10)
    except Exception:
        pass

MENU = [[{"text": "🎁 5GB Key ရယူရန်", "callback_data": "claim"}],
        [{"text": "🔑 ကျွန်တော့် Key", "callback_data": "mykey"},
         {"text": "📊 အသုံးပြုမှု", "callback_data": "usage"}]]

WELCOME = ("👋 မင်္ဂလာပါ <b>GOLDENSKY Free 5GB</b> Bot ပါ\n\n"
           "ဒီ Bot ကနေ <b>တစ်ရက် 5GB</b> သုံးနိုင်တဲ့ Server Key ကို အခမဲ့ ရယူနိုင်ပါတယ်။ "
           "5GB ကုန်ရင် နောက်နေ့ ပြန်ပြည့်ပါတယ် (Key အဟောင်းပဲ ဆက်သုံးရတာပါ)။\n\n"
           "စဖို့ အောက်က ခလုတ်ကို နှိပ်ပါ 👇")

# ---------------- Marzban helpers ----------------
_mz_token = {"tok": None}

def mz_req(method, path, data=None, form=False, _retry=True):
    headers = {}
    body = None
    if _mz_token["tok"]:
        headers["Authorization"] = "Bearer " + _mz_token["tok"]
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(MZ_BASE + path, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if e.code == 401 and _retry:
            _mz_token["tok"] = None
            mz_login()
            return mz_req(method, path, data, form, _retry=False)
        raise

def mz_login():
    r = mz_req("POST", "/api/admin/token",
               {"username": MZ_USER, "password": MZ_PASS}, form=True, _retry=False)
    _mz_token["tok"] = r["access_token"]

def mz_get_user(name):
    try:
        return mz_req("GET", "/api/user/" + name)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise

def mz_create_user(name, note):
    body = {
        "username": name,
        "proxies": {"vless": {"flow": "xtls-rprx-vision"}, "shadowsocks": {}},
        "inbounds": {"vless": ["VLESS TCP REALITY"], "shadowsocks": ["Shadowsocks TCP"]},
        "expire": int(time.time()) + KEY_DAYS * 24 * 3600,
        "data_limit": KEY_GB * 1024 ** 3,
        "data_limit_reset_strategy": "day",
        "status": "active",
        "note": note,
    }
    return mz_req("POST", "/api/user", body)

def mz_renew_user(name):
    body = {"expire": int(time.time()) + KEY_DAYS * 24 * 3600, "status": "active"}
    return mz_req("PUT", "/api/user/" + name, body)

# ---------------- formatting ----------------
def fmt_bytes(n):
    n = float(n or 0)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024 or unit == "TB":
            return ("%.2f %s" % (n, unit)) if unit in ("GB", "TB") else ("%d %s" % (int(n), unit))
        n /= 1024.0

def fmt_date(ts):
    if not ts:
        return "-"
    return time.strftime("%Y-%m-%d", time.gmtime(int(ts) + 6 * 3600 + 30 * 60))

def pick_links(user):
    ss = vless = ""
    for lnk in user.get("links") or []:
        if lnk.startswith("ss://") and not ss:
            ss = lnk
        elif lnk.startswith("vless://") and not vless:
            vless = lnk
    sub = user.get("subscription_url") or ""
    if sub and not sub.startswith("http"):
        sub = PUBLIC_BASE + sub
    return ss, vless, sub

def key_message(user, fresh):
    ss, vless, sub = pick_links(user)
    head = "✅ <b>Key ရပါပြီ!</b>" if fresh else "🔑 <b>သင့်ရဲ့ Key</b>"
    parts = [head,
             "📦 Data: <b>%dGB / တစ်ရက်</b> (နေ့တိုင်း ပြန်ပြည့်)" % KEY_GB,
             "📅 သက်တမ်း: %s အထိ" % fmt_date(user.get("expire")), ""]
    if ss:
        parts.append("🚀 <b>Shadowsocks</b> (အရင် စမ်းရန်):")
        parts.append("<code>%s</code>" % html.escape(ss))
        parts.append("")
    if vless:
        parts.append("🌐 <b>VLESS</b>:")
        parts.append("<code>%s</code>" % html.escape(vless))
        parts.append("")
    if sub:
        parts.append("🔗 <b>Subscription</b> (v2rayNG မှာ Import ရန်):")
        parts.append("<code>%s</code>" % html.escape(sub))
        parts.append("")
    parts.append("📌 သုံးနည်း: Key ကို copy လုပ်ပြီး GOLDENSKY App (သို့ v2rayNG) မှာ paste ထည့် → Connect")
    return "\n".join(parts)

def usage_message(user):
    used = user.get("used_traffic") or 0
    limit = user.get("data_limit") or 0
    pct = (100.0 * used / limit) if limit else 0
    status = {"active": "✅ Active", "limited": "⛔ Limited (ဒီနေ့ ကုန်ပြီ)",
              "expired": "⌛ Expired", "disabled": "🚫 Disabled"}.get(user.get("status"), user.get("status"))
    return ("📊 <b>အသုံးပြုမှု</b>\n\n"
            "အခြေအနေ: %s\n"
            "သုံးပြီး: <b>%s</b> / %s (%.1f%%)\n"
            "📅 သက်တမ်း: %s အထိ\n\n"
            "ℹ️ Data က နေ့တိုင်း သူ့အလိုလို ပြန်ပြည့်ပါတယ်" %
            (status, fmt_bytes(used), fmt_bytes(limit), pct, fmt_date(user.get("expire"))))

# ---------------- state (update offset + claim throttle) ----------------
def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except Exception:
        return {"offset": 0, "claims": {}}

def save_state(st):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_PATH)

STATE = load_state()

# ---------------- handlers ----------------
def uname_for(tg_user):
    return "tg_" + str(tg_user["id"])

def get_or_create(tg_user):
    name = uname_for(tg_user)
    user = mz_get_user(name)
    if user:
        if user.get("status") == "expired":
            user = mz_renew_user(name)
        return user, False
    note = "tg %s %s" % (tg_user["id"], (tg_user.get("first_name") or "")[:40])
    return mz_create_user(name, note), True

def handle_claim(chat_id, tg_user):
    now = time.time()
    last = STATE["claims"].get(str(tg_user["id"]), 0)
    if now - last < 60:
        send(chat_id, "⏳ ခဏ စောင့်ပြီး ပြန်နှိပ်ပါ (1 မိနစ် အတွင်း တစ်ခါပဲ)")
        return
    STATE["claims"][str(tg_user["id"])] = now
    save_state(STATE)
    try:
        user, fresh = get_or_create(tg_user)
        send(chat_id, key_message(user, fresh), MENU)
    except Exception as e:
        print("claim failed:", e, file=sys.stderr)
        send(chat_id, "⚠️ Server ဘက် အခက် ဖြစ်နေပါတယ်။ ခဏနေ ပြန် ကြိုးစားပါ")

def handle_mykey(chat_id, tg_user):
    try:
        user = mz_get_user(uname_for(tg_user))
        if not user:
            send(chat_id, "Key မရှိသေးပါ။ '🎁 5GB Key ရယူရန်' ကို နှိပ်ပါ", MENU)
            return
        if user.get("status") == "expired":
            user = mz_renew_user(uname_for(tg_user))
        send(chat_id, key_message(user, False), MENU)
    except Exception as e:
        print("mykey failed:", e, file=sys.stderr)
        send(chat_id, "⚠️ Server ဘက် အခက် ဖြစ်နေပါတယ်။ ခဏနေ ပြန် ကြိုးစားပါ")

def handle_usage(chat_id, tg_user):
    try:
        user = mz_get_user(uname_for(tg_user))
        if not user:
            send(chat_id, "Key မရှိသေးပါ။ '🎁 5GB Key ရယူရန်' ကို နှိပ်ပါ", MENU)
            return
        send(chat_id, usage_message(user), MENU)
    except Exception as e:
        print("usage failed:", e, file=sys.stderr)
        send(chat_id, "⚠️ Server ဘက် အခက် ဖြစ်နေပါတယ်။ ခဏနေ ပြန် ကြိုးစားပါ")

def process(update):
    if "message" in update:
        m = update["message"]
        chat_id = m["chat"]["id"]
        text = (m.get("text") or "").strip()
        if text.startswith("/start"):
            send(chat_id, WELCOME, MENU)
        elif text.startswith("/mykey"):
            handle_mykey(chat_id, m["from"])
        elif text.startswith("/usage"):
            handle_usage(chat_id, m["from"])
        else:
            send(chat_id, WELCOME, MENU)
    elif "callback_query" in update:
        cb = update["callback_query"]
        chat_id = cb["message"]["chat"]["id"]
        data = cb.get("data")
        answer_cb(cb["id"])
        if data == "claim":
            handle_claim(chat_id, cb["from"])
        elif data == "mykey":
            handle_mykey(chat_id, cb["from"])
        elif data == "usage":
            handle_usage(chat_id, cb["from"])

def main():
    mz_login()
    print("bot started, marzban login OK", flush=True)
    while True:
        try:
            r = tg_call("getUpdates", {"offset": STATE["offset"], "timeout": 30,
                                       "allowed_updates": ["message", "callback_query"]}, timeout=40)
            for u in r.get("result", []):
                STATE["offset"] = u["update_id"] + 1
                try:
                    process(u)
                except Exception as e:
                    print("process error:", e, file=sys.stderr)
            save_state(STATE)
        except Exception as e:
            print("poll error:", e, file=sys.stderr)
            time.sleep(5)

if __name__ == "__main__":
    main()
BOTPYEOF
python3 -m py_compile /opt/gs-bot/bot.py && echo "OK: bot.py syntax valid"

# ---------- config ----------
ADMIN_PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
[ -n "$ADMIN_PASS" ] || { echo "!! Could not read the Marzban admin password from /root/marzban-login.txt"; exit 1; }
TOKEN=""
if [ -f /opt/gs-bot/bot.env ]; then
  TOKEN=$(grep "^BOT_TOKEN=" /opt/gs-bot/bot.env | cut -d= -f2- || true)
fi
if [ -z "$TOKEN" ]; then
  echo ""
  echo "BotFather token is needed. In Telegram: @BotFather -> /newbot -> copy the token."
  read -rsp "Paste the bot token here (input hidden): " TOKEN; echo ""
fi
[ -n "$TOKEN" ] || { echo "!! Empty token. Aborting."; exit 1; }
cat > /opt/gs-bot/bot.env <<ENVEOF
BOT_TOKEN=$TOKEN
MZ_BASE=http://127.0.0.1:8000
MZ_USER=admin
MZ_PASS=$ADMIN_PASS
PUBLIC_BASE=https://$DOMAIN:8443
KEY_GB=5
KEY_DAYS=30
ENVEOF
chmod 600 /opt/gs-bot/bot.env
echo "OK: config written (/opt/gs-bot/bot.env, 600)"

# ---------- systemd service ----------
cat > /etc/systemd/system/gs-tgbot.service <<'UNIT'
[Unit]
Description=GOLDENSKY Telegram Bot (5GB/day keys via Marzban)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/gs-bot
ExecStart=/usr/bin/python3 /opt/gs-bot/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable gs-tgbot >/dev/null 2>&1 || true
systemctl restart gs-tgbot
sleep 4
if ! systemctl is-active --quiet gs-tgbot; then
  echo "!! Bot service failed to start. Last log lines:"
  journalctl -u gs-tgbot -n 25 --no-pager || true
  exit 1
fi

# ---------- verify token with Telegram ----------
BOTUSER=$(python3 - <<'PYEOF' || true
import json, urllib.request
tok = ""
for line in open("/opt/gs-bot/bot.env"):
    if line.startswith("BOT_TOKEN="):
        tok = line.strip().split("=", 1)[1]
try:
    with urllib.request.urlopen("https://api.telegram.org/bot" + tok + "/getMe", timeout=15) as r:
        d = json.load(r)
    print("@" + d["result"]["username"] if d.get("ok") else "")
except Exception:
    print("")
PYEOF
)
echo "=================================================================="
echo " Telegram Bot - DONE"
echo "   Service : gs-tgbot (active)"
if [ -n "$BOTUSER" ]; then
  echo "   Bot     : https://t.me/${BOTUSER#@}  ($BOTUSER)"
else
  echo "   Bot     : token saved, but Telegram getMe check failed -"
  echo "             check the token and: journalctl -u gs-tgbot -n 20"
fi
echo "   Keys    : 5GB/day per Telegram user, auto-refill daily, 30-day expiry"
echo "   Test    : open the bot, tap Start, then the '5GB Key' button"
echo "=================================================================="
