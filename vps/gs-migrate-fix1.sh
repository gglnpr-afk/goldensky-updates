#!/usr/bin/env bash
# gs-migrate-fix1.sh — run on FirstByte JP (root). Completes the Xray part
# of the migration that gs-migrate-install.sh safely aborted: the merged
# config had a duplicate inbound tag ("None-mig") because untagged AWS
# inbounds were renamed identically. This version assigns guaranteed-
# unique tags, shows the xray -test output, auto-restores the old config
# if xray does not come up, then runs the SS/VMess/VLESS client proofs.
# Hysteria2 is already migrated — not touched here.
set -uo pipefail
BUNDLE=/root/gs-migrate-bundle.tar.gz
XRAY_CFG=/usr/local/etc/xray/config.json
XRAY_BIN=/usr/local/bin/xray
EXPECT_IP=132.243.30.145
RESULTS=""
result() { RESULTS="$RESULTS
$1: $2"; echo "  [$2] $1"; }

[ "$(id -u)" = "0" ] || { echo "Run as root:  bash gs-migrate-fix1.sh"; exit 1; }
HN="$(hostname)"; PUBIP="$(curl -s --max-time 6 ifconfig.me || echo unknown)"
echo "Box: hostname=$HN public_ip=$PUBIP"
if [ "$PUBIP" = "52.194.182.108" ] || [ "$HN" = "ip-172-26-3-211" ]; then
  echo "ABORT: this is the AWS Tokyo box itself."; exit 1
fi
[ -f "$BUNDLE" ] || { echo "ABORT: $BUNDLE not found."; exit 1; }
[ -f "$XRAY_CFG" ] || { echo "ABORT: no $XRAY_CFG on this box."; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar -xzf "$BUNDLE" -C "$WORK"
AWS_XRAY="$WORK/payload/_usr_local_etc_xray_config.json"
[ -f "$AWS_XRAY" ] || { echo "ABORT: bundle has no AWS xray config."; exit 1; }

echo "=== Xray merge (unique-tag fix) ==="
MERGED=/root/merged-fixed.json
python3 - "$XRAY_CFG" "$AWS_XRAY" "$MERGED" <<'PYEOF'
import json, sys, copy
tgt = json.load(open(sys.argv[1])); aws = json.load(open(sys.argv[2]))
tin = tgt.setdefault("inbounds", [])
by_port = {}
for ib in tin: by_port.setdefault(ib.get("port"), ib)
tags = {ib.get("tag") for ib in tin if ib.get("tag")}
conflicts = []
def uniq_tag(base):
    t = base or "inbound-mig"
    cand, n = t, 2
    while cand in tags:
        cand = f"{t}-mig" if n == 2 else f"{t}-mig{n}"; n += 1
    tags.add(cand); return cand
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
        nib["tag"] = uniq_tag(nib.get("tag"))
        tin.append(nib); by_port[port] = nib
        print(f"  ADD {proto} :{port} (tag {nib['tag']})"); continue
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
        print(f"  MERGE ss :{port} (+{len(newp)}, total {len(clients)})")
    else:
        have = {c.get("id") for c in ts.get("clients") or []}
        tc = ts.setdefault("clients", []); added = 0
        for c in as_.get("clients") or []:
            if c.get("id") and c["id"] not in have:
                nc = copy.deepcopy(c); nc.setdefault("email", "migrated"); tc.append(nc); have.add(c["id"]); added += 1
        print(f"  {'MERGE' if added else 'OK  '} {proto} :{port} (+{added}, total {len(tc)})")
if conflicts:
    print("CONFLICTS:", *conflicts, sep="\n  !! "); sys.exit(3)
# final sweep: guarantee unique non-empty tags across ALL inbounds
seen = set()
for ib in tin:
    t = ib.get("tag")
    if not t: continue
    if t in seen: ib["tag"] = uniq_tag(t)
    seen.add(ib["tag"])
json.dump(tgt, open(sys.argv[3], "w"), indent=2)
print("  merged -> " + sys.argv[3])
PYEOF
rc=$?
[ $rc -eq 3 ] && { echo "ABORT: port conflict — config untouched."; exit 1; }
[ $rc -ne 0 ] && { echo "ABORT: merge error rc=$rc — config untouched."; exit 1; }

echo "=== xray -test on merged config:"
"$XRAY_BIN" run -test -config "$MERGED" 2>&1 | tail -2
if ! "$XRAY_BIN" run -test -config "$MERGED" >/dev/null 2>&1; then
  echo "ABORT: xray still rejects the merged config — live config untouched."
  exit 1
fi

BAK="$XRAY_CFG.pre-migrate-$(date +%Y%m%d-%H%M%S)"
cp -a "$XRAY_CFG" "$BAK"
cp "$MERGED" "$XRAY_CFG"
systemctl restart xray
sleep 2
if systemctl is-active --quiet xray; then
  result "Xray merge" "PASS - merged config live, xray active"
else
  echo "!! xray did not come up — restoring $BAK"
  cp -a "$BAK" "$XRAY_CFG"; systemctl restart xray; sleep 2
  result "Xray merge" "FAIL - restored previous config (report to Muse)"
  journalctl -u xray -n 12 --no-pager | tail -12
  echo "=== SUMMARY ===$RESULTS"; exit 1
fi

echo "=== Self-tests (AWS credentials against 127.0.0.1) ==="
TESTD="$WORK/clients"; mkdir -p "$TESTD"
python3 - "$AWS_XRAY" "$TESTD" <<'PYEOF'
import json, sys, os
aws = json.load(open(sys.argv[1])); outdir = sys.argv[2]
socks = {"shadowsocks": 11090, "vmess": 11091, "vless": 11092}
for ib in aws.get("inbounds", []):
    proto, port, s = ib.get("protocol"), ib.get("port"), ib.get("settings") or {}
    if proto not in socks: continue
    ob = None
    if proto == "shadowsocks":
        pw = s.get("password") or ((s.get("clients") or [{}])[0].get("password"))
        if not pw: continue
        ob = {"protocol": "shadowsocks", "settings": {"servers": [
            {"address": "127.0.0.1", "port": port, "method": s.get("method"), "password": pw}]}}
    elif proto == "vmess":
        cl = (s.get("clients") or [{}])[0]
        if not cl.get("id"): continue
        ob = {"protocol": "vmess", "settings": {"vnext": [
            {"address": "127.0.0.1", "port": port, "users": [
                {"id": cl["id"], "alterId": cl.get("alterId", 0), "security": "auto"}]}]}}
    elif proto == "vless":
        cl = (s.get("clients") or [{}])[0]
        if not cl.get("id"): continue
        u = {"id": cl["id"], "encryption": "none"}
        if cl.get("flow"): u["flow"] = cl["flow"]
        ob = {"protocol": "vless", "settings": {"vnext": [
            {"address": "127.0.0.1", "port": port, "users": [u]}]}}
    if ib.get("streamSettings"): ob["streamSettings"] = ib["streamSettings"]
    cfg = {"log": {"loglevel": "none"},
           "inbounds": [{"listen": "127.0.0.1", "port": socks[proto], "protocol": "socks",
                         "settings": {"udp": False}}],
           "outbounds": [ob]}
    json.dump(cfg, open(os.path.join(outdir, proto + ".json"), "w"))
    print("  test config ready:", proto)
PYEOF
for proto in shadowsocks vmess vless; do
  f="$TESTD/$proto.json"; [ -f "$f" ] || continue
  case $proto in shadowsocks) SP=11090 ;; vmess) SP=11091 ;; vless) SP=11092 ;; esac
  "$XRAY_BIN" run -config "$f" >/dev/null 2>&1 &
  XPID=$!
  sleep 2
  GOT="$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:$SP https://ifconfig.me || true)"
  kill $XPID 2>/dev/null; wait $XPID 2>/dev/null
  if [ "$GOT" = "$EXPECT_IP" ]; then
    result "Test $proto" "PASS - exit IP $GOT"
  else
    result "Test $proto" "FAIL - got '${GOT:-nothing}' (want $EXPECT_IP)"
  fi
done

echo "=== SUMMARY ===$RESULTS"
echo
echo "All PASS = the Xray migration is done. Remaining step: Cloudflare"
echo "second A record for busterzone.mobi -> 132.243.30.145."
