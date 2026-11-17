#!/bin/bash
# fix-hosts-final.sh - run on AWS JP, the PANEL box (as root).
# Final follow-up to fix-hosts-domains.sh / fix-hosts-core.sh. Live
# panel output showed why the core (JP) links still used the raw IP:
# in /api/hosts the core entries (remarks
# "🚀 Marz ({USERNAME}) [{PROTOCOL} - {TRANSPORT}]", tags
# "VLESS TCP REALITY" and "Shadowsocks TCP") carry the literal
# placeholder address "{SERVER_IP}", which Marzban substitutes with
# the server IP at link-generation time. The earlier scripts only
# matched "" or the raw IP, so they never touched it.
# This script sets the address of EVERY non-node host entry to
# marz.gloriafreeproton.io, whatever it currently holds
# ("{SERVER_IP}", "", a raw IP, anything):
#   - node entries (remark contains "AWS-SG") are NEVER modified,
#     even if their address differed
#   - no entries are created or deleted; only the "address" field
#     of core entries changes
# Safety: the panel password is read from /root/marzban-login.txt and
# is never printed; the full hosts JSON is backed up to
# /root/hosts-backup-final-<unix_ts>.json (0600) BEFORE anything
# changes; the script is idempotent - a re-run with correct core
# addresses changes nothing.
set -u
[ "$(id -u)" = "0" ] || { echo "run as root: sudo bash fix-hosts-final.sh"; exit 1; }
PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
[ -n "$PASS" ] || { echo "!! cannot read the panel password from /root/marzban-login.txt"; exit 1; }
export GS_MZ_PASS="$PASS"
python3 - <<'PYEOF'
import json, os, sys, time, urllib.request, urllib.parse, urllib.error

BASE = "http://127.0.0.1:8000"
DOMAIN = "marz.gloriafreeproton.io"
JP_IP = "52.194.182.108"
SG_DOMAIN = "sg.mobileking.vip"
NODE_MARK = "AWS-SG"
BACKUP_DIR = os.environ.get("GS_BACKUP_DIR", "/root")
PROBE_USERS = ["tg_6424256355", "awsprobe"]

def req(method, path, data=None, token=None, form=False):
    headers, body = {}, None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(BASE + path, data=body, headers=headers, method=method)
    with urllib.request.urlopen(r, timeout=30) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else {}

try:
    tok = req("POST", "/api/admin/token",
              {"username": "admin", "password": os.environ["GS_MZ_PASS"]}, form=True)["access_token"]
except Exception as e:
    print("!! panel login failed:", e)
    sys.exit(1)
print("OK: panel login")

try:
    hosts = req("GET", "/api/hosts", token=tok)
except Exception as e:
    print("!! GET /api/hosts failed:", e)
    sys.exit(1)

print("")
print("--- hosts BEFORE ---")
for tag, entries in hosts.items():
    for h in entries or []:
        print("%s | %s | %s" % (tag, h.get("remark"), h.get("address")))

backup = os.path.join(BACKUP_DIR, "hosts-backup-final-%d.json" % int(time.time()))
with open(backup, "w") as f:
    json.dump(hosts, f, indent=2)
os.chmod(backup, 0o600)
print("OK: hosts backup saved (%s, 600)" % backup)

changed = 0
for tag, entries in hosts.items():
    for h in entries or []:
        if NODE_MARK in (h.get("remark") or ""):
            continue
        if h.get("address") != DOMAIN:
            print("  set [%s] remark=%r address %r -> %s"
                  % (tag, h.get("remark"), h.get("address"), DOMAIN))
            h["address"] = DOMAIN
            changed += 1

if changed:
    try:
        req("PUT", "/api/hosts", hosts, token=tok)
    except Exception as e:
        print("!! PUT /api/hosts failed:", e)
        sys.exit(1)
    print("OK: hosts updated (%d core addresses set to %s)" % (changed, DOMAIN))
else:
    print("NOTE: nothing to change")

print("")
print("--- user links ---")
all_links = []
for name in PROBE_USERS:
    try:
        u = req("GET", "/api/user/" + name, token=tok)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            continue
        print("note: GET /api/user/%s said HTTP %s" % (name, e.code))
        continue
    except Exception as e:
        print("note: GET /api/user/%s failed: %s" % (name, e))
        continue
    links = u.get("links") or []
    print("user %s: %d link(s)" % (name, len(links)))
    for lnk in links:
        print("  " + lnk)
        all_links.append(lnk)

joined = "\n".join(all_links)
vl_ok = any(l.startswith("vless://") and ("@" + DOMAIN) in l for l in all_links)
ss_ok = any(l.startswith("ss://") and ("@" + DOMAIN) in l for l in all_links)
print("")
print("--- VERDICT ---")
print("JP IP %s in links: %s" % (JP_IP, "YES" if JP_IP in joined else "NO"))
print("%s VLESS link: %s" % (DOMAIN, "YES" if vl_ok else "NO"))
print("%s SS link: %s" % (DOMAIN, "YES" if ss_ok else "NO"))
print("%s links still present: %s" % (SG_DOMAIN, "YES" if SG_DOMAIN in joined else "NO"))

try:
    after = req("GET", "/api/hosts", token=tok)
except Exception:
    after = hosts
print("")
print("--- hosts AFTER ---")
for tag, entries in after.items():
    for h in entries or []:
        print("%s | %s | %s" % (tag, h.get("remark"), h.get("address")))
PYEOF
rc=$?
[ "$rc" = "0" ] || exit "$rc"
echo ""
echo "=== END ==="
echo "Check the bot: tap 'My Key'"
