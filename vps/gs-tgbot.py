#!/usr/bin/env python3
# GOLDENSKY Telegram bot - issues 5GB/day trial Marzban keys (paid keys via @BlackRain03).
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
KEY_GB = int(CFG.get("KEY_GB", "50"))
KEY_DAYS = int(CFG.get("KEY_DAYS", "30"))
ADMIN_ID = (CFG.get("ADMIN_ID") or "").strip()
BANNER_PATH = "/opt/gs-bot/banner.png"
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

def tg_photo_upload(chat_id, caption, buttons):
    """Upload the banner photo via multipart. Returns the Telegram result."""
    boundary = "----gsbot%d" % int(time.time() * 1000)
    with open(BANNER_PATH, "rb") as f:
        img = f.read()
    chunks = []
    fields = {"chat_id": str(chat_id), "caption": caption, "parse_mode": "HTML"}
    if buttons:
        fields["reply_markup"] = json.dumps({"inline_keyboard": buttons})
    for k, v in fields.items():
        chunks.append(("--" + boundary + "\r\n"
                       "Content-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (k, v)).encode())
    chunks.append(("--" + boundary + "\r\n"
                   "Content-Disposition: form-data; name=\"photo\"; filename=\"banner.png\"\r\n"
                   "Content-Type: image/png\r\n\r\n").encode())
    chunks.append(img)
    chunks.append(("\r\n--" + boundary + "--\r\n").encode())
    req = urllib.request.Request(TG + "/sendPhoto", data=b"".join(chunks),
                                 headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

def set_commands():
    base = [{"command": "start", "description": "ပြန်စရန်"},
            {"command": "mykey", "description": "ကိုယ့် Key ကြည့်ရန်"},
            {"command": "usage", "description": "အသုံးပြုမှု ကြည့်ရန်"}]
    try:
        tg_call("setMyCommands", {"commands": base, "scope": {"type": "default"}}, timeout=15)
        tg_call("setChatMenuButton", {"menu_button": {"type": "commands"}}, timeout=15)
        if ADMIN_ID:
            tg_call("setMyCommands",
                    {"commands": base + [{"command": "stats", "description": "Bot အခြေအနေ (Admin)"},
                                         {"command": "broadcast", "description": "လူအားလုံးဆီ စာပို့ (Admin)"}],
                     "scope": {"type": "chat", "chat_id": int(ADMIN_ID)}}, timeout=15)
            tg_call("setChatMenuButton",
                    {"chat_id": int(ADMIN_ID), "menu_button": {"type": "commands"}}, timeout=15)
        print("commands menu set", flush=True)
    except Exception as e:
        print("setMyCommands failed:", e, file=sys.stderr)

BUY_URL = "https://t.me/BlackRain03"
CLAIM_LABEL = "🎁 %dGB အစမ်း ရယူရန်" % KEY_GB
MENU = [[{"text": CLAIM_LABEL, "callback_data": "claim"},
         {"text": "💰 ကီးဝယ်ယူရန်", "url": BUY_URL}],
        [{"text": "🔑 ကျွန်တော့် Key", "callback_data": "mykey"},
         {"text": "📊 အသုံးပြုမှု", "callback_data": "usage"}]]

WELCOME_BODY = ("👋 မင်္ဂလာပါ <b>GOLDENSKY</b> Bot ပါ\n\n"
                "ဒီ Bot ကနေ <b>တစ်ရက် %dGB အစမ်း</b> Server Key ကို အခမဲ့ ရယူနိုင်ပါတယ်။ "
                "%dGB ကုန်ရင် နောက်နေ့ ပြန်ပြည့်ပါတယ် (Key အဟောင်းပဲ ဆက်သုံးရတာပါ)။\n\n"
                "💰 <b>ပိုသုံးချင်ရင်</b> အခပေး Key ကို @BlackRain03 မှာ ဝယ်ယူနိုင်ပါတယ်။") % (KEY_GB, KEY_GB)
WELCOME_TAIL = "စဖို့ အောက်က ခလုတ်ကို နှိပ်ပါ 👇"

def welcome_text():
    parts = [WELCOME_BODY]
    try:
        parts.append("👥 အသုံးပြုသူ စုစုပေါင်း: <b>%d</b> ယောက်" % len(bot_users()))
    except Exception as e:
        print("user count failed:", e, file=sys.stderr)
    parts.append(WELCOME_TAIL)
    return "\n\n".join(parts)

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
        "proxies": {"vless": {}, "shadowsocks": {}},
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

def mz_all_users():
    r = mz_req("GET", "/api/users?offset=0&limit=1000")
    return r.get("users") or []

def bot_users():
    return [u for u in mz_all_users() if (u.get("username") or "").startswith("tg_")]

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
    parts.append("")
    parts.append("💰 အစမ်း %dGB ထက် ပိုသုံးချင်ရင် အခပေး Key ကို @BlackRain03 မှာ ဝယ်နိုင်ပါတယ်" % KEY_GB)
    return "\n".join(parts)

def usage_message(user):
    used = user.get("used_traffic") or 0
    limit = user.get("data_limit") or 0
    pct = (100.0 * used / limit) if limit else 0
    filled = int(round(pct / 10.0))
    if filled > 10:
        filled = 10
    bar = "█" * filled + "░" * (10 - filled)
    status = {"active": "✅ Active", "limited": "⛔ Limited (ဒီနေ့ ကုန်ပြီ)",
              "expired": "⌛ Expired", "disabled": "🚫 Disabled"}.get(user.get("status"), user.get("status"))
    return ("📊 <b>အသုံးပြုမှု</b>\n\n"
            "အခြေအနေ: %s\n"
            "သုံးပြီး: <b>%s</b> / %s (%.1f%%)\n"
            "%s %.1f%%\n"
            "📅 သက်တမ်း: %s အထိ\n\n"
            "ℹ️ Data က နေ့တိုင်း သူ့အလိုလို ပြန်ပြည့်ပါတယ်" %
            (status, fmt_bytes(used), fmt_bytes(limit), pct, bar, pct, fmt_date(user.get("expire"))))

def stats_message():
    users = bot_users()
    counts = {}
    used = 0
    life = 0
    for u in users:
        st = u.get("status") or "?"
        counts[st] = counts.get(st, 0) + 1
        used += u.get("used_traffic") or 0
        life += u.get("lifetime_used_traffic") or 0
    return ("📈 <b>Bot အခြေအနေ</b> (Admin သာ)\n\n"
            "👥 Key ယူထားသူ: <b>%d</b> ယောက်\n"
            "✅ Active: %d\n"
            "⛔ Limited (ဒီနေ့ %dGB ကုန်): %d\n"
            "⌛ Expired: %d\n"
            "🚫 Disabled: %d\n\n"
            "📦 Reset နောက်ပိုင်း သုံးပြီး (စုစုပေါင်း): <b>%s</b>\n"
            "♾️ စတင်ချိန်မှ စုစုပေါင်း: <b>%s</b>" %
            (len(users), counts.get("active", 0), KEY_GB, counts.get("limited", 0),
             counts.get("expired", 0), counts.get("disabled", 0),
             fmt_bytes(used), fmt_bytes(life)))

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
            send(chat_id, "Key မရှိသေးပါ။ '%s' ကို နှိပ်ပါ" % CLAIM_LABEL, MENU)
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
            send(chat_id, "Key မရှိသေးပါ။ '%s' ကို နှိပ်ပါ" % CLAIM_LABEL, MENU)
            return
        send(chat_id, usage_message(user), MENU)
    except Exception as e:
        print("usage failed:", e, file=sys.stderr)
        send(chat_id, "⚠️ Server ဘက် အခက် ဖြစ်နေပါတယ်။ ခဏနေ ပြန် ကြိုးစားပါ")

def send_welcome(chat_id):
    text = welcome_text()
    fid = STATE.get("banner_file_id")
    try:
        if fid:
            tg_call("sendPhoto", {"chat_id": chat_id, "photo": fid, "caption": text,
                                  "parse_mode": "HTML",
                                  "reply_markup": {"inline_keyboard": MENU}}, timeout=20)
            return
        if os.path.exists(BANNER_PATH):
            r = tg_photo_upload(chat_id, text, MENU)
            photos = (r.get("result") or {}).get("photo") or []
            if photos:
                STATE["banner_file_id"] = photos[-1]["file_id"]
                save_state(STATE)
            return
    except Exception as e:
        print("banner send failed:", e, file=sys.stderr)
        STATE.pop("banner_file_id", None)
    send(chat_id, text, MENU)

def handle_stats(chat_id, tg_user):
    if not ADMIN_ID or str(tg_user["id"]) != ADMIN_ID:
        send(chat_id, welcome_text(), MENU)
        return
    try:
        send(chat_id, stats_message())
    except Exception as e:
        print("stats failed:", e, file=sys.stderr)
        send(chat_id, "⚠️ Stats ဖတ်လို့ မရပါ။ ခဏနေ ပြန် ကြိုးစားပါ")

# ---------------- broadcast (admin only) ----------------
BC_TTL = 600

def bc_pending():
    p = STATE.get("broadcast")
    if p and time.time() - p.get("ts", 0) > BC_TTL:
        STATE["broadcast"] = None
        save_state(STATE)
        return None
    return p

def bc_recipient_count():
    try:
        return len(bot_users())
    except Exception:
        return None

def handle_broadcast_cmd(chat_id, tg_user):
    if not ADMIN_ID or str(tg_user["id"]) != ADMIN_ID:
        send(chat_id, welcome_text(), MENU)
        return
    STATE["broadcast"] = {"step": "await_text", "ts": time.time()}
    save_state(STATE)
    n = bc_recipient_count()
    who = ("လူ %d ယောက်လုံး (Key ယူထားသူတွေ)" % n) if n is not None else "Key ယူထားသူတွေ အားလုံး"
    send(chat_id, "📢 <b>Broadcast</b>\n\nပို့ချင်တဲ့ စာကို ဒီမှာ ရိုက်ပို့ပါ — %s ဆီ ရောက်ပါမယ်။\n"
                  "မပို့ချင်ရင် /cancel လို့ ပို့ပါ" % who)

def bc_capture_text(chat_id, text):
    draft = "📢 <b>အသိပေးချက်</b>\n\n" + html.escape(text)
    STATE["broadcast"] = {"step": "confirm", "ts": time.time(), "text": draft}
    save_state(STATE)
    n = bc_recipient_count()
    label = ("✅ ပို့မယ် (%d ယောက်)" % n) if n is not None else "✅ ပို့မယ်"
    btns = [[{"text": label, "callback_data": "bc_send"},
             {"text": "❌ မပို့ဘူး", "callback_data": "bc_cancel"}]]
    send(chat_id, "📢 <b>Broadcast Preview</b> — ဒီစာ ရောက်သွားပါမယ်:\n\n" + draft, btns)

def bc_send_one(chat_id, text):
    try:
        tg_call("sendMessage", {"chat_id": chat_id, "text": text, "parse_mode": "HTML",
                                "disable_web_page_preview": True}, timeout=15)
        return True
    except Exception:
        return False

def bc_do_send(chat_id):
    p = STATE.get("broadcast") or {}
    draft = p.get("text")
    STATE["broadcast"] = None
    save_state(STATE)
    if not draft:
        send(chat_id, "⚠️ Broadcast စာ မရှိတော့ပါ။ /broadcast ကနေ ပြန်စပါ")
        return
    try:
        users = bot_users()
    except Exception as e:
        print("broadcast user list failed:", e, file=sys.stderr)
        send(chat_id, "⚠️ User စာရင်း ဖတ်မရပါ။ ခဏနေ /broadcast ကနေ ပြန်စပါ")
        return
    ok = fail = 0
    for u in users:
        uname = u.get("username") or ""
        if not uname[3:].isdigit():
            continue
        if bc_send_one(int(uname[3:]), draft):
            ok += 1
        else:
            fail += 1
        time.sleep(0.05)
    send(chat_id, "📢 <b>Broadcast ပြီးပါပြီ</b>\n\n"
                  "✅ ရောက်သူ: %d ယောက်\n"
                  "❌ မရောက် (Bot ကို Block ထားသူ စသည်): %d ယောက်" % (ok, fail))

def bc_cancel(chat_id):
    STATE["broadcast"] = None
    save_state(STATE)
    send(chat_id, "❌ Broadcast ကို ဖျက်လိုက်ပါပြီ")

def process(update):
    if "message" in update:
        m = update["message"]
        chat_id = m["chat"]["id"]
        text = (m.get("text") or "").strip()
        pend = bc_pending()
        is_admin = bool(ADMIN_ID) and str(m["from"]["id"]) == ADMIN_ID
        if text.startswith("/broadcast"):
            handle_broadcast_cmd(chat_id, m["from"])
        elif text.startswith("/cancel") and pend and is_admin:
            bc_cancel(chat_id)
        elif pend and pend.get("step") == "await_text" and is_admin and text and not text.startswith("/"):
            bc_capture_text(chat_id, text)
        elif text.startswith("/start"):
            send_welcome(chat_id)
        elif text.startswith("/mykey"):
            handle_mykey(chat_id, m["from"])
        elif text.startswith("/usage"):
            handle_usage(chat_id, m["from"])
        elif text.startswith("/stats"):
            handle_stats(chat_id, m["from"])
        else:
            send(chat_id, welcome_text(), MENU)
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
        elif data == "bc_send":
            if ADMIN_ID and str(cb["from"]["id"]) == ADMIN_ID:
                bc_do_send(chat_id)
        elif data == "bc_cancel":
            if ADMIN_ID and str(cb["from"]["id"]) == ADMIN_ID:
                bc_cancel(chat_id)

def main():
    mz_login()
    print("bot started, marzban login OK", flush=True)
    set_commands()
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
