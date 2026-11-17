#!/bin/bash
# fix-hosts-domains.sh - run on AWS JP, the PANEL box (as root).
# Purpose: Marzban currently generates user links with raw IPs in the
# host "address" fields. Rewrite them to domains so already-issued keys
# keep working through future IP changes / DNS flips:
#     52.194.182.108 (AWS JP, panel local) -> marz.gloriafreeproton.io
#     47.129.129.29  (AWS SG node)         -> sg.mobileking.vip
# Both domains already resolve to those IPs (verified before publishing).
# Safety: the panel password is read from /root/marzban-login.txt and is
# never printed; the full hosts JSON is backed up to
# /root/hosts-backup-<unix_ts>.json (0600) BEFORE anything changes;
# ONLY host "address" fields are touched; the script is idempotent -
# a re-run that finds no raw-IP addresses changes nothing.
set -u
[ "$(id -u)" = "0" ] || { echo "run as root: sudo bash fix-hosts-domains.sh"; exit 1; }
PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
[ -n "$PASS" ] || { echo "!! cannot read the panel password from /root/marzban-login.txt"; exit 1; }
export GS_MZ_PASS="$PASS"
python3 - <<'PYEOF'
import json, os, sys, time, urllib.request, urllib.parse, urllib.error

BASE = "http://127.0.0.1:8000"
REWRITE = {
    "52.194.182.108": "marz.gloriafreeproton.io",
    "47.129.129.29": "sg.mobileking.vip",
}
PROBE_USERS = ["awsprobe", "tg_6424256355"]

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
        print("  %s: remark=%r address=%s" % (tag, h.get("remark"), h.get("address")))

backup = "/root/hosts-backup-%d.json" % int(time.time())
with open(backup, "w") as f:
    json.dump(hosts, f, indent=2)
os.chmod(backup, 0o600)
print("OK: hosts backup saved (%s, 600)" % backup)

changed = 0
for tag, entries in hosts.items():
    for h in entries or []:
        if h.get("address") in REWRITE:
            print("  rewrite [%s] %s -> %s" % (tag, h["address"], REWRITE[h["address"]]))
            h["address"] = REWRITE[h["address"]]
            changed += 1

if changed:
    try:
        req("PUT", "/api/hosts", hosts, token=tok)
    except Exception as e:
        print("!! PUT /api/hosts failed:", e)
        sys.exit(1)
    print("OK: hosts updated (%d changed)" % changed)
else:
    print("NOTE: no raw-IP addresses found in hosts - nothing changed")

print("")
print("--- probe user links ---")
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
print("")
print("--- VERDICT ---")
for ip in REWRITE:
    print("IP %s still present in links: %s" % (ip, "YES" if ip in joined else "NO"))
for dom in REWRITE.values():
    print("domain %s in links: %s" % (dom, "YES" if dom in joined else "NO"))
PYEOF
rc=$?
[ "$rc" = "0" ] || exit "$rc"
echo ""
echo "=== END ==="
echo "Now check the bot: tap 'My Key' - links must show marz.gloriafreeproton.io and sg.mobileking.vip"
