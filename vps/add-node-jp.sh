#!/bin/bash
# add-node-jp.sh - run on the MARZBAN box (as root).
# Registers FirstByte JP (jp.mobileking.vip) as a Marzban node and prints the
# panel certificate (base64, one line) that the JP installer needs.
# Idempotent: re-running shows the existing node and requests a reconnect.
set -u
[ "$(id -u)" = "0" ] || { echo "run as root: sudo bash add-node-jp.sh"; exit 1; }
PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
[ -n "$PASS" ] || { echo "!! cannot read the panel password from /root/marzban-login.txt"; exit 1; }
export GS_MZ_PASS="$PASS"
python3 - <<'PYEOF'
import base64, hashlib, json, os, sys, urllib.request, urllib.parse, urllib.error

BASE = "http://127.0.0.1:8000"
NODE_NAME = "GS-JP"
NODE_ADDR = "jp.mobileking.vip"

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

cert = req("GET", "/api/node/settings", token=tok)["certificate"]
with open("/root/gs-node-cert.pem", "w") as f:
    f.write(cert)
os.chmod("/root/gs-node-cert.pem", 0o600)
b64 = base64.b64encode(cert.encode()).decode()
with open("/root/gs-node-cert.b64", "w") as f:
    f.write(b64)
print("OK: panel certificate saved (/root/gs-node-cert.pem, 600)")
print("CERT-SHA256 (first 16):", hashlib.sha256(cert.encode()).hexdigest()[:16])

nodes = req("GET", "/api/nodes", token=tok)
mine = [n for n in nodes if n.get("address") == NODE_ADDR or n.get("name") == NODE_NAME]
if mine:
    n = mine[0]
    print("Node already registered: id=%s name=%s address=%s status=%s"
          % (n.get("id"), n.get("name"), n.get("address"), n.get("status")))
    try:
        req("POST", "/api/node/%s/reconnect" % n["id"], token=tok)
        print("OK: reconnect requested - check the panel (Nodes) in a few seconds")
    except Exception as e:
        print("note: reconnect call said:", e)
else:
    try:
        n = req("POST", "/api/node",
                {"name": NODE_NAME, "address": NODE_ADDR, "port": 62050,
                 "api_port": 62051, "usage_coefficient": 1, "add_as_new_host": True},
                token=tok)
        print("OK: node created: id=%s name=%s status=%s"
              % (n.get("id"), n.get("name"), n.get("status")))
    except urllib.error.HTTPError as e:
        print("!! node create returned HTTP", e.code, "-", e.read().decode()[:300])
        nodes = req("GET", "/api/nodes", token=tok)
        mine = [n for n in nodes if n.get("address") == NODE_ADDR or n.get("name") == NODE_NAME]
        if mine:
            print("...but the node record exists anyway: id=%s status=%s"
                  % (mine[0].get("id"), mine[0].get("status")))
        else:
            print("...and no node record was created. Send this output to Muse.")
            sys.exit(1)

print("")
print("=== JP installer argument: long-press COPY this whole line ===")
print(b64)
print("=== END (paste it as the argument of setup-node-jp.sh on FirstByte JP) ===")
PYEOF
