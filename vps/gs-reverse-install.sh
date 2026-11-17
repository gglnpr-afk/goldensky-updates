#!/usr/bin/env bash
# gs-reverse-install.sh — run on the AWS JP TOKYO box (ubuntu):
#   sudo bash gs-reverse-install.sh
#
# REVERSE of gs-migrate-install.sh (2026-11-09): moves every GOLDENSKY
# service that was built on FirstByte JP (132.243.30.145) BACK to this
# AWS box (52.194.182.108), on top of the original stack that already
# runs here with identical credentials.
#
# What it does, fully automatically:
#   0. PULLS /root/gs-reverse-bundle.tar.gz from FirstByte JP with scp
#      (you type the FirstByte ROOT password in this terminal once).
#      Skip the pull with a local bundle:  LOCAL_BUNDLE=1 sudo bash ...
#      or pass a bundle path as $1.
#   1. MERGES the FirstByte Xray inbounds (SS / VMess / VLESS, every
#      client, incl. the SS promo :8390 inbound) into this box's live
#      Xray config — backup first, xray -test before anything goes
#      live, abort-on-conflict with the config untouched, auto-restore
#      if xray does not come back up. NEVER overwrites the config.
#   2. Installs the add-*/gs-* helper scripts, owner link files and
#      guard crons from the bundle (existing files backed up first).
#   3. Installs TUIC (gs-tuic, sing-box, UDP 443) and the WireGuard
#      shop (wg-quick@wg500, UDP 500) FRESH from the bundle — neither
#      exists on AWS yet. Aborts that section (only) if its UDP port
#      is already bound by something unexpected.
#   4. Proves SS / VMess / VLESS end-to-end with real client configs
#      against 127.0.0.1 (exit IP must read 52.194.182.108) and checks
#      TUIC / WG are active and listening. Prints a PASS/FAIL summary.
#
# NOT touched: Hysteria2 (the original AWS HY2 already runs here with
# the same credentials) and the Marzban GS-JP node (separate step).
# DNS is NOT changed by this script — the Cloudflare flip is the
# separate final step after every proof passes.
set -uo pipefail

SRC_IP="132.243.30.145"
EXPECT_IP="52.194.182.108"
BUNDLE=/root/gs-reverse-bundle.tar.gz
XRAY_BIN=/usr/local/bin/xray
RESULTS=""
TS="$(date +%Y%m%d-%H%M%S)"

note() { echo; echo "=== $* ==="; }
result() { RESULTS="$RESULTS
$1: $2"; echo "  [$2] $1"; }
backup() { # backup <file> — timestamped copy if the file exists
  [ -e "$1" ] && cp -a "$1" "$1.pre-reverse-$TS" && echo "  backup: $1.pre-reverse-$TS"
  return 0
}

[ "$(id -u)" = "0" ] || { echo "Run as root:  sudo bash gs-reverse-install.sh"; exit 1; }
HN="$(hostname)"
PUBIP="$(curl -s --max-time 6 ifconfig.me || echo unknown)"
echo "Box: hostname=$HN public_ip=$PUBIP"
if [ "$PUBIP" = "$SRC_IP" ] || ip addr 2>/dev/null | grep -q "$SRC_IP"; then
  echo "ABORT: this is the FirstByte JP box itself — run this on AWS JP (ubuntu, sudo)."
  exit 1
fi
if [ "$PUBIP" != "$EXPECT_IP" ] && [ "$PUBIP" != "unknown" ]; then
  echo "WARNING: public IP is $PUBIP, expected $EXPECT_IP (AWS JP)."
  echo "         Self-tests below check the exit IP against $EXPECT_IP."
fi

############################ 0. PULL THE BUNDLE ############################
if [ -n "${1:-}" ] && [ -f "$1" ]; then
  echo "Using bundle given on the command line: $1"
  BUNDLE="$1"
elif [ "${LOCAL_BUNDLE:-0}" = "1" ] && [ -f "$BUNDLE" ]; then
  echo "LOCAL_BUNDLE=1 — using existing $BUNDLE (no pull)."
elif [ "${LOCAL_BUNDLE:-0}" = "1" ]; then
  echo "ABORT: LOCAL_BUNDLE=1 but $BUNDLE does not exist on this box."
  exit 1
else
  note "Pulling bundle from FirstByte JP ($SRC_IP) — type its ROOT password when asked"
  if scp -o StrictHostKeyChecking=accept-new "root@$SRC_IP:/root/gs-reverse-bundle.tar.gz" "$BUNDLE"; then
    echo "  pull OK"
  elif [ -f "$BUNDLE" ]; then
    echo "  !! scp failed — falling back to the bundle already on this box:"
    echo "     $BUNDLE (dated $(date -r "$BUNDLE" -Is 2>/dev/null))"
  else
    echo "ABORT: scp failed and no local bundle exists."
    echo "       First run gs-reverse-collect.sh on FirstByte JP."
    exit 1
  fi
fi
chmod 600 "$BUNDLE" 2>/dev/null || true
echo "Bundle: $BUNDLE ($(du -h "$BUNDLE" | cut -f1), sha256 $(sha256sum "$BUNDLE" | cut -c1-16)...)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar -xzf "$BUNDLE" -C "$WORK"
PAYLOAD="$WORK/payload"
[ -d "$PAYLOAD" ] || { echo "ABORT: bundle has no payload/ — wrong file?"; exit 1; }
note "Bundle manifest"
cat "$PAYLOAD/MANIFEST.txt" 2>/dev/null || echo "(no MANIFEST.txt — old bundle?)"

# Source Xray config inside the bundle: canonical mirrored path first,
# then wherever the collect script recorded it.
SRC_XRAY=""
if [ -f "$PAYLOAD/usr/local/etc/xray/config.json" ]; then
  SRC_XRAY="$PAYLOAD/usr/local/etc/xray/config.json"
elif [ -f "$PAYLOAD/gs-meta/xray-config-path.txt" ]; then
  REL="$(head -1 "$PAYLOAD/gs-meta/xray-config-path.txt" | tr -d ' \r\n' | sed 's:^/::')"
  [ -n "$REL" ] && [ -f "$PAYLOAD/$REL" ] && SRC_XRAY="$PAYLOAD/$REL"
fi

# This box's live Xray config: canonical path, same fallback search.
XRAY_CFG=""
for cand in /usr/local/etc/xray/config.json /etc/xray/config.json; do
  if [ -f "$cand" ]; then XRAY_CFG="$cand"; break; fi
done
if [ -z "$XRAY_CFG" ]; then
  echo "ABORT: no Xray config found on this AWS box (looked in /usr/local/etc/xray, /etc/xray)."
  exit 1
fi
echo "AWS Xray config: $XRAY_CFG"
echo "Bundle Xray config: ${SRC_XRAY:-NOT IN BUNDLE}"

############################ 1. XRAY MERGE ############################
note "Xray merge (FirstByte inbounds -> this box, merge never overwrite)"
if [ -z "$SRC_XRAY" ]; then
  result "Xray merge" "SKIP - no xray config in bundle"
elif [ ! -x "$XRAY_BIN" ]; then
  result "Xray merge" "FAIL - no xray binary at $XRAY_BIN"
else
  MERGED="$WORK/merged.json"
  python3 - "$XRAY_CFG" "$SRC_XRAY" "$MERGED" <<'PYMERGE'
import json, sys, copy
tgt_path, src_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
tgt = json.load(open(tgt_path)); src = json.load(open(src_path))
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

for aib in src.get("inbounds", []):
    port, proto = aib.get("port"), aib.get("protocol")
    if port is None or proto not in ("shadowsocks", "vmess", "vless"):
        print(f"  skip source inbound port={port} proto={proto} (not migrated)")
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
        conflicts.append(f"port {port}: this box={tib.get('protocol')} source={proto}")
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
        have = {c.get("id") for c in ts.get("clients") or []}
        added = 0
        tc = ts.setdefault("clients", [])
        for c in as_.get("clients") or []:
            if c.get("id") and c["id"] not in have:
                nc = copy.deepcopy(c); nc.setdefault("email", "migrated")
                tc.append(nc); have.add(c["id"]); added += 1
        print(f"  {'MERGE' if added else 'OK  '} {proto} :{port} (+{added} client(s), total {len(tc)})")

if conflicts:
    print("CONFLICTS:")
    for c in conflicts: print("  !! " + c)
    sys.exit(3)
# final sweep: guarantee unique non-empty tags across ALL inbounds
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
PYMERGE
  rc=$?
  if [ $rc -eq 3 ]; then
    result "Xray merge" "ABORTED - port conflict, config untouched (report to Muse)"
  elif [ $rc -ne 0 ]; then
    result "Xray merge" "FAIL - merge script error rc=$rc (report to Muse)"
  elif "$XRAY_BIN" run -test -config "$MERGED" >/dev/null 2>&1 || "$XRAY_BIN" -test -config "$MERGED" >/dev/null 2>&1; then
    BAK="$XRAY_CFG.pre-reverse-$TS"
    cp -a "$XRAY_CFG" "$BAK"
    cp "$MERGED" "$XRAY_CFG"
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
      result "Xray merge" "PASS - merged, xray restarted and active"
    else
      echo "  !! xray did not come up — restoring $BAK"
      cp -a "$BAK" "$XRAY_CFG"; systemctl restart xray; sleep 2
      result "Xray merge" "FAIL - restored previous config (backup $BAK)"
      journalctl -u xray -n 15 --no-pager | tail -15
    fi
  else
    result "Xray merge" "FAIL - merged config rejected by xray -test, config untouched"
  fi
fi

############################ 2. SCRIPTS / ROOT FILES / CRON ############################
note "Helper scripts, owner files, guard crons"
INSTALLED=0
# /usr/local/bin helpers (TUIC/WG binaries are handled in their own
# sections below and excluded here)
if [ -d "$PAYLOAD/usr/local/bin" ]; then
  for f in "$PAYLOAD/usr/local/bin"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in sing-box|gs-stats-query) continue ;; esac
    case "$base" in add-*|del-*|gs-*|list-*|remove-*|tuic-render.py)
      backup "/usr/local/bin/$base"
      install -m 755 "$f" "/usr/local/bin/$base"
      INSTALLED=$((INSTALLED+1)); echo "  + /usr/local/bin/$base" ;;
    esac
  done
fi
# /root owner files (links, registries, usage status)
if [ -d "$PAYLOAD/root" ]; then
  for f in "$PAYLOAD/root"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in my-*.txt|*-users.txt|tuic-domain.txt|ss-promo-usage.txt|tuic-quota-status.txt|wg-usage.txt|add-*.sh|gs-*.sh)
      backup "/root/$base"
      cp -a "$f" "/root/$base"; chmod 600 "/root/$base" 2>/dev/null || true
      INSTALLED=$((INSTALLED+1)); echo "  + /root/$base" ;;
    esac
  done
fi
# /etc/cron.d guard entries shipped in the bundle
if [ -d "$PAYLOAD/etc/cron.d" ]; then
  for f in "$PAYLOAD/etc/cron.d"/gs-*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    backup "/etc/cron.d/$base"
    install -m 644 "$f" "/etc/cron.d/$base"
    INSTALLED=$((INSTALLED+1)); echo "  + /etc/cron.d/$base"
  done
fi
# Root-crontab guard lines (WG shop installs its guard via crontab):
# merge ONLY the known guard lines, de-duplicated. Other FirstByte
# crontab lines are listed in the manifest and deliberately not copied.
if [ -f "$PAYLOAD/gs-meta/root-crontab.txt" ]; then
  GUARD_LINES="$(grep -E 'gs-wg-guard|gs-promo-guard|gs-tuic-guard|gs-quota-guard|gs-free-guard' "$PAYLOAD/gs-meta/root-crontab.txt" || true)"
  if [ -n "$GUARD_LINES" ]; then
    CUR="$(crontab -l 2>/dev/null || true)"
    NEW="$CUR"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$CUR" in *"$line"*) echo "  = crontab already has: $line" ;;
        *) NEW="$NEW
$line"; echo "  + crontab: $line" ;;
      esac
    done <<EOF
$GUARD_LINES
EOF
    printf '%s\n' "$NEW" | crontab -
  fi
fi
result "Scripts/files/cron" "PASS - $INSTALLED file(s) installed (backups *.pre-reverse-$TS)"

############################ 3. TUIC (fresh install) ############################
note "TUIC (gs-tuic, sing-box, UDP 443) — fresh install from bundle"
SB_SRC="$PAYLOAD/usr/local/etc/sing-box"
SB_DIR=/usr/local/etc/sing-box
if [ ! -f "$SB_SRC/config.json" ]; then
  result "TUIC install" "SKIP - no sing-box config in bundle"
else
  # binary: prefer the bundle's custom quota build; fall back to a
  # sing-box already on this box. Never download — the quota build is
  # custom and a stock binary would break the guard's stats.
  SB_OK=0
  if [ -f "$PAYLOAD/usr/local/bin/sing-box" ]; then
    backup /usr/local/bin/sing-box
    install -m 755 "$PAYLOAD/usr/local/bin/sing-box" /usr/local/bin/sing-box; SB_OK=1
    echo "  sing-box binary installed from bundle"
  elif [ -x /usr/local/bin/sing-box ]; then
    SB_OK=1; echo "  using sing-box already on this box"
  fi
  if [ -f "$PAYLOAD/usr/local/bin/gs-stats-query" ]; then
    backup /usr/local/bin/gs-stats-query
    install -m 755 "$PAYLOAD/usr/local/bin/gs-stats-query" /usr/local/bin/gs-stats-query
  fi
  if [ "$SB_OK" != "1" ]; then
    result "TUIC install" "FAIL - no sing-box binary in bundle or on this box"
  elif ss -lunp 2>/dev/null | grep -q ":443 " && ! systemctl is-active --quiet gs-tuic; then
    result "TUIC install" "ABORTED - UDP 443 already bound by something unexpected (see ss output in manifest step), TUIC untouched"
    ss -lunp 2>/dev/null | grep ":443 " || true
  else
    if [ -d "$SB_DIR" ]; then
      cp -a "$SB_DIR" "$SB_DIR.pre-reverse-$TS"; echo "  backup: $SB_DIR.pre-reverse-$TS/"
    fi
    mkdir -p "$SB_DIR"
    cp -a "$SB_SRC"/. "$SB_DIR"/
    chmod 600 "$SB_DIR/key.pem" 2>/dev/null || true
    echo "  NOTE: the TUIC cert was issued for FirstByte (SAN: domain + 132.243.30.145)."
    echo "        Domain clients (jp.mobileking.vip) are unaffected; IP-direct clients may"
    echo "        need a re-issued cert — check MANIFEST.txt tuic_cert_san and tell Muse."
    if [ -f "$PAYLOAD/etc/systemd/system/gs-tuic.service" ]; then
      backup /etc/systemd/system/gs-tuic.service
      install -m 644 "$PAYLOAD/etc/systemd/system/gs-tuic.service" /etc/systemd/system/gs-tuic.service
    else
      backup /etc/systemd/system/gs-tuic.service
      cat > /etc/systemd/system/gs-tuic.service <<'UNIT'
[Unit]
Description=TUIC server (sing-box)
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
      echo "  gs-tuic unit written (bundle had none — canonical unit used)"
    fi
    if /usr/local/bin/sing-box check -c "$SB_DIR/config.json" >/dev/null 2>&1; then
      systemctl daemon-reload
      systemctl enable gs-tuic >/dev/null 2>&1 || true
      systemctl restart gs-tuic
      sleep 3
      if systemctl is-active --quiet gs-tuic && ss -lunp 2>/dev/null | grep -q ":443 "; then
        result "TUIC install" "PASS - gs-tuic active, UDP 443 listening"
      else
        result "TUIC install" "FAIL - gs-tuic not active / UDP 443 not listening"
        journalctl -u gs-tuic -n 15 --no-pager | tail -15
      fi
    else
      echo "  !! sing-box check failed — restoring previous config dir"
      rm -rf "$SB_DIR"; [ -d "$SB_DIR.pre-reverse-$TS" ] && cp -a "$SB_DIR.pre-reverse-$TS" "$SB_DIR"
      result "TUIC install" "FAIL - sing-box rejected the config, previous config restored"
    fi
  fi
fi

############################ 4. WIREGUARD SHOP (fresh install) ############################
note "WireGuard shop (wg-quick@wg500, UDP 500) — fresh install from bundle"
WG_SRC="$PAYLOAD/etc/wireguard/wg500.conf"
if [ ! -f "$WG_SRC" ]; then
  result "WireGuard install" "SKIP - no wg500.conf in bundle"
elif ss -lunp 2>/dev/null | grep -q ":500 " && ! systemctl is-active --quiet wg-quick@wg500; then
  result "WireGuard install" "ABORTED - UDP 500 already bound by something unexpected, WG untouched"
  ss -lunp 2>/dev/null | grep ":500 " || true
else
  if ! command -v wg >/dev/null 2>&1; then
    echo "  wireguard-tools missing — installing..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq wireguard-tools iptables >/dev/null 2>&1 || true
  fi
  if ! command -v wg >/dev/null 2>&1; then
    result "WireGuard install" "FAIL - wireguard-tools unavailable (apt failed)"
  else
    mkdir -p /etc/wireguard /root/wg-keys /var/lib/gs-wg
    backup /etc/wireguard/wg500.conf
    install -m 600 "$WG_SRC" /etc/wireguard/wg500.conf
    # The copied PostUp/PostDown NAT rules name FirstByte's WAN
    # interface — rewrite them to THIS box's real WAN interface.
    WANIF="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [ -n "$WANIF" ]; then
      sed -i -E "s/(-o )[A-Za-z0-9_.-]+( -j MASQUERADE)/\1$WANIF\2/g" /etc/wireguard/wg500.conf
      echo "  NAT interface in wg500.conf set to $WANIF"
    fi
    for extra in clients.db host.txt; do
      [ -f "$PAYLOAD/etc/wireguard/$extra" ] && cp -a "$PAYLOAD/etc/wireguard/$extra" "/etc/wireguard/$extra"
    done
    if [ -d "$PAYLOAD/root/wg-keys" ]; then
      cp -a "$PAYLOAD/root/wg-keys"/. /root/wg-keys/ 2>/dev/null || true
      chmod 600 /root/wg-keys/* 2>/dev/null || true
    fi
    if [ -d "$PAYLOAD/var/lib/gs-wg" ]; then
      cp -a "$PAYLOAD/var/lib/gs-wg"/. /var/lib/gs-wg/ 2>/dev/null || true
    fi
    if [ -f "$PAYLOAD/etc/sysctl.d/99-wg500.conf" ]; then
      cp -a "$PAYLOAD/etc/sysctl.d/99-wg500.conf" /etc/sysctl.d/99-wg500.conf
    else
      echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg500.conf
    fi
    sysctl -p /etc/sysctl.d/99-wg500.conf >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable wg-quick@wg500 >/dev/null 2>&1 || true
    systemctl restart wg-quick@wg500
    sleep 2
    PEERS="$(wg show wg500 peers 2>/dev/null | wc -l)"
    if systemctl is-active --quiet wg-quick@wg500 && ss -lunp 2>/dev/null | grep -q ":500 "; then
      result "WireGuard install" "PASS - wg500 active, UDP 500 listening, $PEERS peer(s)"
    else
      result "WireGuard install" "FAIL - wg500 not active / UDP 500 not listening"
      journalctl -u wg-quick@wg500 -n 15 --no-pager | tail -15
    fi
  fi
fi

############################ 5. SELF-TESTS ############################
note "Self-tests (real client configs against 127.0.0.1, exit must be $EXPECT_IP)"
TESTD="$WORK/clients"; mkdir -p "$TESTD"
if [ -n "$SRC_XRAY" ] && [ -x "$XRAY_BIN" ]; then
  python3 - "$SRC_XRAY" "$TESTD" <<'PYTEST'
import json, sys, os
src = json.load(open(sys.argv[1])); outdir = sys.argv[2]
sp = 11090
lines = []
for ib in src.get("inbounds", []):
    proto, port, s = ib.get("protocol"), ib.get("port"), ib.get("settings") or {}
    if proto not in ("shadowsocks", "vmess", "vless") or port is None:
        continue
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
           "inbounds": [{"listen": "127.0.0.1", "port": sp, "protocol": "socks",
                         "settings": {"udp": False}}],
           "outbounds": [ob]}
    name = f"{proto}-{port}"
    json.dump(cfg, open(os.path.join(outdir, name + ".json"), "w"))
    lines.append(f"{name} {sp}")
    print("  test config ready:", name, "via socks", sp)
    sp += 1
open(os.path.join(outdir, "tests.txt"), "w").write("\n".join(lines) + ("\n" if lines else ""))
PYTEST
  while read -r TNAME TPORT; do
    [ -n "$TNAME" ] || continue
    f="$TESTD/$TNAME.json"; [ -f "$f" ] || continue
    "$XRAY_BIN" run -config "$f" >/dev/null 2>&1 &
    XPID=$!
    sleep 2
    GOT="$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:$TPORT https://ifconfig.me || true)"
    kill $XPID 2>/dev/null; wait $XPID 2>/dev/null
    if [ "$GOT" = "$EXPECT_IP" ]; then
      result "Test $TNAME" "PASS - exit IP $GOT"
    else
      result "Test $TNAME" "FAIL - got '${GOT:-nothing}' (want $EXPECT_IP)"
    fi
  done < "$TESTD/tests.txt"
else
  result "Self-tests" "SKIP - no source xray config in bundle or no xray binary"
fi
# TUIC / WG service state in the summary (installed in sections 3/4)
if systemctl cat gs-tuic >/dev/null 2>&1; then
  if systemctl is-active --quiet gs-tuic; then
    result "Service gs-tuic" "PASS - active"
  else
    result "Service gs-tuic" "FAIL - unit exists but not active"
  fi
fi
if systemctl cat wg-quick@wg500 >/dev/null 2>&1; then
  if systemctl is-active --quiet wg-quick@wg500; then
    result "Service wg-quick@wg500" "PASS - active"
  else
    result "Service wg-quick@wg500" "FAIL - unit exists but not active"
  fi
fi

note "SUMMARY"
echo "$RESULTS"
echo
echo "Backups of everything changed carry the suffix .pre-reverse-$TS"
echo "(the sing-box config dir backup is a directory with that suffix)."
echo
echo "NOT done by this kit, on purpose:"
echo "  * Hysteria2 — the original AWS HY2 already runs here, untouched."
echo "  * Marzban GS-JP node — moves in a separate step."
echo "  * DNS — if every proof PASSes, the final step is Cloudflare:"
echo "    busterzone.mobi: remove the $SRC_IP A record (keep $EXPECT_IP);"
echo "    jp.mobileking.vip: point the A record at $EXPECT_IP."
echo "    Then field-test one key of each type on the phone (mobile data)."
