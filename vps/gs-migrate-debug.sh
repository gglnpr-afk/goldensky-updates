#!/usr/bin/env bash
# gs-migrate-debug.sh — run on FirstByte JP (root) after a gs-migrate-install
# run whose Xray merge was rejected by xray -test. Changes NOTHING: it
# re-runs the merge into /root/merged-debug.json and shows the REAL xray
# error, plus inbound summaries of both configs (ports/protocols only).
set -uo pipefail
BUNDLE=/root/gs-migrate-bundle.tar.gz
XRAY_CFG=/usr/local/etc/xray/config.json
XRAY_BIN=/usr/local/bin/xray

echo "== xray on THIS box: $($XRAY_BIN -version 2>/dev/null | head -1)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar -xzf "$BUNDLE" -C "$WORK"
AWS_XRAY="$WORK/payload/_usr_local_etc_xray_config.json"
echo "== bundle manifest:"; cat "$WORK/payload/manifest.txt" 2>/dev/null

python3 - "$XRAY_CFG" "$AWS_XRAY" <<'PYEOF'
import json, sys
for name, p in (("THIS BOX", sys.argv[1]), ("AWS", sys.argv[2])):
    cfg = json.load(open(p))
    print(f"-- {name} inbounds:")
    for ib in cfg.get("inbounds", []):
        s = ib.get("settings") or {}
        n = len(s.get("clients") or []) or (1 if s.get("password") else 0)
        print(f"   :{ib.get('port')} {ib.get('protocol')} tag={ib.get('tag')} clients={n}")
    print(f"   outbounds: {[o.get('protocol') for o in cfg.get('outbounds', [])]}")
    print(f"   top-level keys: {sorted(cfg.keys())}")
PYEOF

echo "== merge attempt:"
python3 - "$XRAY_CFG" "$AWS_XRAY" /root/merged-debug.json <<'PYEOF'
import json, sys, copy
tgt = json.load(open(sys.argv[1])); aws = json.load(open(sys.argv[2]))
tin = tgt.setdefault("inbounds", [])
by_port = {}
for ib in tin: by_port.setdefault(ib.get("port"), ib)
tags = {ib.get("tag") for ib in tin}
conflicts = []
def ss_passwords(s):
    pws = []
    if s.get("password"): pws.append(s["password"])
    for c in s.get("clients") or []:
        if c.get("password"): pws.append(c["password"])
    return pws
for aib in aws.get("inbounds", []):
    port, proto = aib.get("port"), aib.get("protocol")
    if port is None or proto not in ("shadowsocks", "vmess", "vless"):
        print(f"  skip aws :{port} {proto}"); continue
    tib = by_port.get(port)
    if tib is None:
        nib = copy.deepcopy(aib)
        if nib.get("tag") in tags: nib["tag"] = str(nib.get("tag")) + "-mig"
        tin.append(nib); by_port[port] = nib; tags.add(nib.get("tag"))
        print(f"  ADD {proto} :{port}"); continue
    if tib.get("protocol") != proto:
        conflicts.append(f"port {port}: box={tib.get('protocol')} aws={proto}"); continue
    ts = tib.setdefault("settings", {}); as_ = aib.get("settings") or {}
    if proto == "shadowsocks":
        if (ts.get("method") or as_.get("method")) and ts.get("method") != as_.get("method"):
            conflicts.append(f"port {port}: SS method differs"); continue
        have = ss_passwords(ts); newp = [p for p in ss_passwords(as_) if p not in have]
        if not newp: print(f"  OK ss :{port} identical"); continue
        clients = list(ts.get("clients") or [])
        if ts.get("password"):
            clients.insert(0, {"password": ts["password"], "email": "existing"}); ts.pop("password", None)
        for p in newp: clients.append({"password": p, "email": "migrated"})
        ts["clients"] = clients
        if as_.get("method"): ts["method"] = as_["method"]
        print(f"  MERGE ss :{port} (+{len(newp)})")
    else:
        have = {c.get("id") for c in ts.get("clients") or []}
        tc = ts.setdefault("clients", []); added = 0
        for c in as_.get("clients") or []:
            if c.get("id") and c["id"] not in have:
                nc = copy.deepcopy(c); nc.setdefault("email", "migrated"); tc.append(nc); have.add(c["id"]); added += 1
        print(f"  {'MERGE' if added else 'OK  '} {proto} :{port} (+{added})")
if conflicts:
    print("CONFLICTS:", *conflicts, sep="\n  !! "); sys.exit(3)
json.dump(tgt, open(sys.argv[3], "w"), indent=2)
print("  merged -> /root/merged-debug.json")
PYEOF
echo "merge rc=$?"

echo "== xray -test: THIS box config alone:"
"$XRAY_BIN" run -test -config "$XRAY_CFG" 2>&1 | tail -3
echo "== xray -test: AWS config alone (with THIS box's binary):"
"$XRAY_BIN" run -test -config "$AWS_XRAY" 2>&1 | tail -3
if [ -f /root/merged-debug.json ]; then
  echo "== xray -test: MERGED config (the real error):"
  "$XRAY_BIN" run -test -config /root/merged-debug.json 2>&1 | tail -6
fi
echo "== done — screenshot ALL of this for Muse =="
