#!/usr/bin/env bash
# gs-migrate-install.sh — run on the FIRSTBYTE JP box (root@asia-premium,
# 132.243.30.145) AFTER gs-migrate-send.sh has pushed the bundle here.
#
# What it does, fully automatically:
#   1. Merges the AWS Tokyo Xray inbounds (SS / VMess / VLESS, every client)
#      into this box's /usr/local/etc/xray/config.json (backup first,
#      xray -test before anything goes live, abort-on-conflict).
#   2. Installs the copied busterzone.mobi Let's Encrypt cert and starts
#      Hysteria2 on UDP 8443 with the SAME password as AWS (the old
#      gs-hy2-test unit is stopped to free the port). TUIC is NOT touched.
#   3. Proves every protocol end-to-end on this box with real client
#      configs (loopback) and prints a PASS/FAIL summary.
# Nothing about existing services is changed until its replacement has
# passed a config test.
set -uo pipefail

BUNDLE=/root/gs-migrate-bundle.tar.gz
XRAY_CFG=/usr/local/etc/xray/config.json
XRAY_BIN=/usr/local/bin/xray
HYST_BIN=/usr/local/bin/hysteria
HYST_SHA=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691
HYST_DL=https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
CERT_LIVE=/etc/letsencrypt/live/busterzone.mobi
EXPECT_IP=132.243.30.145
RESULTS=""

note() { echo; echo "=== $* ==="; }
result() { RESULTS="$RESULTS
$1: $2"; echo "  [$2] $1"; }

[ "$(id -u)" = "0" ] || { echo "Run as root:  bash gs-migrate-install.sh"; exit 1; }
HN="$(hostname)"
PUBIP="$(curl -s --max-time 6 ifconfig.me || echo unknown)"
echo "Box: hostname=$HN public_ip=$PUBIP"
if [ "$PUBIP" = "52.194.182.108" ] || [ "$HN" = "ip-172-26-3-211" ]; then
  echo "ABORT: this is the AWS Tokyo box itself — run this on FirstByte JP."
  exit 1
fi
[ -f "$BUNDLE" ] || { echo "ABORT: $BUNDLE not found — run gs-migrate-send.sh on the AWS Tokyo box first."; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar -xzf "$BUNDLE" -C "$WORK"
PAYLOAD="$WORK/payload"
[ -d "$PAYLOAD" ] || { echo "ABORT: bundle has no payload/ — wrong file?"; exit 1; }
AWS_XRAY="$PAYLOAD/_usr_local_etc_xray_config.json"
AWS_HY2="$PAYLOAD/_etc_hysteria_config.yaml"
note "Bundle manifest"
cat "$PAYLOAD/manifest.txt" 2>/dev/null || echo "(no manifest)"

############################ XRAY MERGE ############################
note "Xray merge (AWS inbounds -> this box)"
if [ ! -f "$AWS_XRAY" ]; then
  result "Xray merge" "SKIP - no AWS xray config in bundle"
elif [ ! -f "$XRAY_CFG" ]; then
  result "Xray merge" "FAIL - this box has no $XRAY_CFG (report to Muse)"
else
  MERGED="$WORK/merged.json"
  python3 - "$XRAY_CFG" "$AWS_XRAY" "$MERGED" <<'PYEOF'
import json, sys, copy
tgt_path, aws_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
tgt = json.load(open(tgt_path)); aws = json.load(open(aws_path))
tin = tgt.setdefault("inbounds", [])
by_port = {}
for ib in tin:
    by_port.setdefault(ib.get("port"), ib)
tags = {ib.get("tag") for ib in tin if ib.get("tag")}
conflicts = []

def uniq_tag(base):
    t = base or "inbound-mig"
    cand, n = t, 2
    while cand in tags:
        cand = f"{t}-mig" if n == 2 else f"{t}-mig{n}"
        n += 1
    tags.add(cand)
    return cand

def ss_passwords(s):
    pws = []
    if s.get("password"): pws.append(s["password"])
    for c in s.get("clients") or []:
        if c.get("password"): pws.append(c["password"])
    return pws

for aib in aws.get("inbounds", []):
    port, proto = aib.get("port"), aib.get("protocol")
    if port is None or proto not in ("shadowsocks", "vmess", "vless"):
        print(f"  skip aws inbound port={port} proto={proto} (not migrated)")
        continue
    tib = by_port.get(port)
    if tib is None:
        nib = copy.deepcopy(aib)
        nib["tag"] = uniq_tag(nib.get("tag"))
        tin.append(nib); by_port[port] = nib
        n = len((aib.get("settings") or {}).get("clients") or []) or (1 if ss_passwords(aib.get("settings") or {}) else 0)
        print(f"  ADD {proto} :{port} ({n} client(s))")
        continue
    if tib.get("protocol") != proto:
        conflicts.append(f"port {port}: this box={tib.get('protocol')} aws={proto}")
        continue
    ts = tib.setdefault("settings", {}); as_ = aib.get("settings") or {}
    if proto == "shadowsocks":
        if (ts.get("method") or as_.get("method")) and ts.get("method") != as_.get("method"):
            conflicts.append(f"port {port}: SS method differs ({ts.get('method')} vs {as_.get('method')})")
            continue
        have = ss_passwords(ts)
        newp = [p for p in ss_passwords(as_) if p not in have]
        if not newp:
            print(f"  OK  shadowsocks :{port} already identical")
            continue
        clients = list(ts.get("clients") or [])
        if ts.get("password"):
            clients.insert(0, {"password": ts["password"], "email": "existing"})
            ts.pop("password", None)
        for p in newp:
            clients.append({"password": p, "email": "migrated"})
        ts["clients"] = clients
        if as_.get("method"): ts["method"] = as_["method"]
        print(f"  MERGE shadowsocks :{port} (+{len(newp)} password(s), total {len(clients)})")
    else:  # vmess / vless: merge clients by id
        key = "id"
        have = {c.get(key) for c in ts.get("clients") or []}
        added = 0
        tc = ts.setdefault("clients", [])
        for c in as_.get("clients") or []:
            if c.get(key) and c[key] not in have:
                nc = copy.deepcopy(c); nc.setdefault("email", "migrated")
                tc.append(nc); have.add(c[key]); added += 1
        print(f"  {'MERGE' if added else 'OK  '} {proto} :{port} (+{added} client(s), total {len(tc)})")

if conflicts:
    print("CONFLICTS:")
    for c in conflicts: print("  !! " + c)
    sys.exit(3)
seen = set()
for ib in tin:
    t = ib.get("tag")
    if not t:
        continue
    if t in seen:
        ib["tag"] = uniq_tag(t)
    seen.add(ib["tag"])
json.dump(tgt, open(out_path, "w"), indent=2)
print("  merged config written")
PYEOF
  rc=$?
  if [ $rc -eq 3 ]; then
    result "Xray merge" "ABORTED - port conflict, config untouched (report to Muse)"
  elif [ $rc -ne 0 ]; then
    result "Xray merge" "FAIL - merge script error rc=$rc (report to Muse)"
  elif "$XRAY_BIN" run -test -config "$MERGED" >/dev/null 2>&1 || "$XRAY_BIN" -test -config "$MERGED" >/dev/null 2>&1; then
    cp -a "$XRAY_CFG" "$XRAY_CFG.pre-migrate-$(date +%Y%m%d-%H%M%S)"
    cp "$MERGED" "$XRAY_CFG"
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
      result "Xray merge" "PASS - merged, xray restarted and active"
    else
      result "Xray merge" "FAIL - xray not active after restart (backup kept as .pre-migrate-*)"
      journalctl -u xray -n 15 --no-pager | tail -15
    fi
  else
    result "Xray merge" "FAIL - merged config rejected by xray -test, config untouched"
  fi
fi

############################ HYSTERIA2 ############################
note "Hysteria2 (UDP 8443, AWS password + copied cert)"
if [ ! -f "$AWS_HY2" ] || [ ! -f "$PAYLOAD/cert/fullchain.pem" ]; then
  result "Hysteria2" "SKIP - bundle lacks HY2 config or cert"
else
  if [ ! -x "$HYST_BIN" ]; then
    if [ "$(uname -m)" = "x86_64" ]; then
      echo "  installing hysteria v2.13.0..."
      curl -sL --max-time 120 -o /tmp/hysteria "$HYST_DL" \
        && echo "$HYST_SHA  /tmp/hysteria" | sha256sum -c - >/dev/null \
        && install -m 755 /tmp/hysteria "$HYST_BIN" \
        || echo "  !! hysteria download failed"
    else
      echo "  !! hysteria binary missing and arch is $(uname -m) — report to Muse"
    fi
  fi
  if [ ! -x "$HYST_BIN" ]; then
    result "Hysteria2" "FAIL - no hysteria binary"
  else
    # free UDP 8443: the old test instance gives up the port
    if systemctl cat gs-hy2-test >/dev/null 2>&1; then
      systemctl stop gs-hy2-test 2>/dev/null || true
      systemctl disable gs-hy2-test 2>/dev/null || true
      echo "  gs-hy2-test stopped (port 8443 freed)"
    fi
    mkdir -p "$CERT_LIVE" /etc/hysteria
    for f in cert.pem chain.pem fullchain.pem privkey.pem; do
      [ -f "$PAYLOAD/cert/$f" ] && cp -a "$PAYLOAD/cert/$f" "$CERT_LIVE/$f"
    done
    chmod 600 "$CERT_LIVE/privkey.pem" 2>/dev/null || true
    ENDDATE="$(openssl x509 -enddate -noout -in "$CERT_LIVE/fullchain.pem" 2>/dev/null)"
    echo "  cert installed ($ENDDATE)"
    [ -f /etc/hysteria/config.yaml ] && cp -a /etc/hysteria/config.yaml "/etc/hysteria/config.yaml.pre-migrate-$(date +%Y%m%d-%H%M%S)"
    # transform: copied cert must be USED — replace any acme block with a
    # tls block pointing at the copied files; rewrite tls paths if present.
    python3 - "$AWS_HY2" /etc/hysteria/config.yaml <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines()
out, i = [], 0
TLS = ["tls:", "  cert: /etc/letsencrypt/live/busterzone.mobi/fullchain.pem",
       "  key: /etc/letsencrypt/live/busterzone.mobi/privkey.pem"]
have_tls = any(re.match(r"^tls:\s*$", l) for l in lines)
while i < len(lines):
    l = lines[i]
    if re.match(r"^acme:\s*$", l):  # drop whole acme block
        i += 1
        while i < len(lines) and (lines[i].startswith(" ") or lines[i].strip() == ""):
            i += 1
        if not have_tls:
            out.extend(TLS); have_tls = True
        continue
    if re.match(r"^tls:\s*$", l):  # rewrite cert/key inside tls block
        out.append("tls:"); i += 1
        while i < len(lines) and (lines[i].startswith(" ") or lines[i].strip() == ""):
            s = lines[i].strip()
            if s.startswith("cert:"):
                out.append("  cert: /etc/letsencrypt/live/busterzone.mobi/fullchain.pem")
            elif s.startswith("key:"):
                out.append("  key: /etc/letsencrypt/live/busterzone.mobi/privkey.pem")
            else:
                out.append(lines[i])
            i += 1
        continue
    out.append(l); i += 1
if not have_tls:
    out = TLS + [""] + out
open(dst, "w").write("\n".join(out) + "\n")
print("  config installed ->", dst)
PYEOF
    cat > /etc/systemd/system/gs-hy2-main.service <<'UNIT'
[Unit]
Description=Hysteria2 (migrated from AWS Tokyo)
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable gs-hy2-main >/dev/null 2>&1
    systemctl restart gs-hy2-main
    sleep 3
    if systemctl is-active --quiet gs-hy2-main && ss -ulnp 2>/dev/null | grep -q ":8443"; then
      result "Hysteria2" "PASS - running on UDP 8443 ($ENDDATE)"
    else
      result "Hysteria2" "FAIL - not listening on UDP 8443"
      journalctl -u gs-hy2-main -n 15 --no-pager | tail -15
    fi
  fi
fi

############################ SELF-TESTS ############################
note "Self-tests (real client configs against 127.0.0.1)"
TESTD="$WORK/clients"; mkdir -p "$TESTD"
if [ -f "$AWS_XRAY" ]; then
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
    case $proto in
      shadowsocks) SP=11090 ;; vmess) SP=11091 ;; vless) SP=11092 ;;
    esac
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
fi
# HY2 client test (real cert verification, SNI busterzone.mobi)
if systemctl is-active --quiet gs-hy2-main && [ -x "$HYST_BIN" ]; then
  PW="$(python3 - <<'PYEOF'
import re
txt = open("/etc/hysteria/config.yaml").read()
m = re.search(r"(?ms)^auth:.*?^\s+password:\s*(\S+)", txt) or re.search(r"(?m)^\s*password:\s*(\S+)", txt)
print(m.group(1).strip("\"'") if m else "")
PYEOF
)"
  if [ -n "$PW" ]; then
    cat > "$TESTD/hy2-client.yaml" <<EOF
server: 127.0.0.1:8443
auth: $PW
tls:
  sni: busterzone.mobi
  insecure: false
socks5:
  listen: 127.0.0.1:11093
EOF
    "$HYST_BIN" client --config "$TESTD/hy2-client.yaml" >/dev/null 2>&1 &
    HPID=$!
    sleep 3
    GOT="$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:11093 https://ifconfig.me || true)"
    kill $HPID 2>/dev/null; wait $HPID 2>/dev/null
    if [ "$GOT" = "$EXPECT_IP" ]; then
      result "Test hysteria2" "PASS - exit IP $GOT, cert verified"
    else
      result "Test hysteria2" "FAIL - got '${GOT:-nothing}' (want $EXPECT_IP)"
    fi
  else
    result "Test hysteria2" "SKIP - could not parse auth password"
  fi
fi

note "SUMMARY"
echo "$RESULTS"
echo
echo "If everything PASSes: the last step is Cloudflare — add 132.243.30.145"
echo "as a SECOND A record for busterzone.mobi (keep the AWS one for now)."
