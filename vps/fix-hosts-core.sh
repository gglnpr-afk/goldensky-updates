#!/bin/bash
# fix-hosts-core.sh - run on AWS JP, the PANEL box (as root).
# Follow-up to fix-hosts-domains.sh. That script's live run proved
# /api/hosts contains NO raw-IP addresses: the AWS-SG node entries are
# correct (address sg.mobileking.vip, remarks contain "AWS-SG") and SG
# links already generate with the domain. But the CORE (local JP)
# links still generate with the raw IP 52.194.182.108 (remarks "Marz")
# because the core inbounds have no usable host entry - either no core
# entry at all, or a core entry with an empty address - so Marzban's
# link generator falls back to the server IP.
# This script creates or repairs the core host entries so JP links
# use marz.gloriafreeproton.io:
#   - node entries (remark contains "AWS-SG") are NEVER modified
#   - a core entry with address "" or 52.194.182.108 gets the domain
#     (every other field is left untouched)
#   - a tag with node entries but no core entry gets a core entry
#     cloned from the first node entry (remark "Marz", domain address)
#   - a tag with no entries at all gets a standard "Marz" host entry
# Safety: the panel password is read from /root/marzban-login.txt and
# is never printed; the full hosts JSON is backed up to
# /root/hosts-backup-core-<unix_ts>.json (0600) BEFORE anything
# changes; the script is idempotent - a re-run with correct core
# entries changes nothing.
set -u
[ "$(id -u)" = "0" ] || { echo "run as root: sudo bash fix-hosts-core.sh"; exit 1; }
PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
[ -n "$PASS" ] || { echo "!! cannot read the panel password from /root/marzban-login.txt"; exit 1; }
export GS_MZ_PASS="$PASS"
python3 - <<'PYEOF'
import copy, json, os, sys, time, urllib.request, urllib.parse, urllib.error

BASE = "http://127.0.0.1:8000"
DOMAIN = "marz.gloriafreeproton.io"
JP_IP = "52.194.182.108"
SG_DOMAIN = "sg.mobileking.vip"
NODE_MARK = "AWS-SG"
BACKUP_DIR = os.environ.get("GS_BACKUP_DIR", "/root")
PROBE_USERS = ["tg_6424256355", "awsprobe"]
DEFAULT_HOST = {
    "remark": "Marz", "address": DOMAIN, "port": 0, "path": "",
    "sni": "", "host": "", "security": "inbound_default", "alpn": "",
    "fingerprint": "", "allowinsecure": False, "is_disabled": False,
    "mux_enable": False, "fragment_setting": "", "noise_setting": "",
    "random_user_agent": False, "use_sni_as_host": False,
}

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

backup = os.path.join(BACKUP_DIR, "hosts-backup-core-%d.json" % int(time.time()))
with open(backup, "w") as f:
    json.dump(hosts, f, indent=2)
os.chmod(backup, 0o600)
print("OK: hosts backup saved (%s, 600)" % backup)

# Template node entry (used only to build an entry for a tag whose
# list is completely empty, so the new entry carries the same field
# set/defaults this Marzban version uses).
template = None
for tag, entries in hosts.items():
    for h in entries or []:
        if NODE_MARK in (h.get("remark") or ""):
            template = h
            break
    if template is not None:
        break

repaired = 0
created = 0
for tag in list(hosts.keys()):
    entries = hosts.get(tag)
    if entries is None:
        entries = []
        hosts[tag] = entries
    node_entries = [h for h in entries if NODE_MARK in (h.get("remark") or "")]
    core_entries = [h for h in entries if NODE_MARK not in (h.get("remark") or "")]
    if core_entries:
        for h in core_entries:
            addr = h.get("address")
            if addr is None:
                addr = ""
            if addr in ("", JP_IP):
                h["address"] = DOMAIN
                repaired += 1
                print("  repair [%s] remark=%r -> %s" % (tag, h.get("remark"), DOMAIN))
    elif node_entries:
        clone = copy.deepcopy(node_entries[0])
        clone["remark"] = "Marz"
        clone["address"] = DOMAIN
        entries.append(clone)
        created += 1
        print("  create [%s] core entry cloned from first node entry" % tag)
    else:
        if template is not None:
            entry = copy.deepcopy(template)
            entry["remark"] = "Marz"
            entry["address"] = DOMAIN
            entry["port"] = 0
        else:
            entry = dict(DEFAULT_HOST)
        entries.append(entry)
        created += 1
        print("  create [%s] standard core entry" % tag)

if repaired or created:
    try:
        req("PUT", "/api/hosts", hosts, token=tok)
    except Exception as e:
        print("!! PUT /api/hosts failed:", e)
        sys.exit(1)
    print("OK: hosts updated (repaired=%d created=%d)" % (repaired, created))
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
