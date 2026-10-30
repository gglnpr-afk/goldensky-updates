#!/usr/bin/env bash
# fix-ss-promo-outbounds.sh — GOLDENSKY JP promo fix.
# Bug found 2026-10-30: the standalone Xray config on the JP box has
# "outbounds": [] — the server accepts SS connections but has NO
# outbound to forward traffic to, so every flow dies silently
# (tunnel UP, zero data, usage 0). This script restores the standard
# freedom + blackhole outbounds (only if missing/empty), validates
# with xray -test, restarts xray, then PROVES the fix with the same
# on-box loopback client test that failed before.
set -uo pipefail

CFG="/usr/local/etc/xray/config.json"
XRAY="/usr/local/bin/xray"
PORT=8390

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi

BAK="$CFG.bak.outfix-$(date +%s)"
cp "$CFG" "$BAK"
echo "Backup: $BAK"

python3 - "$CFG" <<'PYEOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
ob = cfg.get("outbounds") or []
if ob:
    print("Outbounds already present:", [o.get("protocol") for o in ob],
          "- leaving config unchanged.")
    sys.exit(0)
cfg["outbounds"] = [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"},
]
json.dump(cfg, open(p, "w"), indent=2)
print("Outbounds were EMPTY - restored freedom(direct) + blackhole(blocked).")
PYEOF

if ! "$XRAY" -test -config "$CFG" >/dev/null 2>&1; then
  echo "xray -test FAILED - restoring backup, nothing changed."
  cp "$BAK" "$CFG"
  exit 1
fi

systemctl daemon-reload
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
  echo "xray did not restart cleanly - restoring backup."
  cp "$BAK" "$CFG"; systemctl restart xray; exit 1
fi
echo "xray restarted, active."
ss -tlnp 2>/dev/null | grep ":$PORT " || echo "(port $PORT not listening yet)"

# --- proof: loopback client test with the live config's password ---
PW="$(python3 - "$CFG" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
for ib in cfg.get("inbounds", []):
    if ib.get("tag") == "ss-promo" or ib.get("port") == 8390:
        s = ib.get("settings", {})
        for c in s.get("clients", []):
            if c.get("password"):
                print(c["password"]); sys.exit(0)
        if s.get("password"):
            print(s["password"]); sys.exit(0)
PYEOF
)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/client.json" <<JSON
{"log": {"loglevel": "warning"},
 "inbounds": [{"listen": "127.0.0.1", "port": 11081, "protocol": "socks",
               "settings": {"udp": true}}],
 "outbounds": [{"protocol": "shadowsocks", "tag": "proxy",
   "settings": {"servers": [{"address": "127.0.0.1", "port": $PORT,
     "method": "aes-128-gcm", "password": "$PW"}]}}]}
JSON
"$XRAY" run -config "$TMP/client.json" >"$TMP/client.log" 2>&1 &
PID=$!
sleep 2
OUT="$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:11081 http://api.ipify.org 2>/dev/null)"
[ -z "$OUT" ] && OUT="$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:11081 http://ifconfig.me/ip 2>/dev/null)"
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

echo
if [ -n "$OUT" ]; then
  echo "=== FIX PROVEN: data flows through promo inbound, exit IP = $OUT ==="
else
  echo "=== STILL FAILING: no data even after outbound restore ==="
  tail -5 "$TMP/client.log"
fi
