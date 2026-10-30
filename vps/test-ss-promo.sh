#!/usr/bin/env bash
# test-ss-promo.sh — GOLDENSKY JP promo SS: on-box end-to-end self test.
# Reads the promo password from the LIVE server config (no typing, no
# transcription), runs a throwaway Xray CLIENT on this box against the
# promo inbound (loopback first, then via the box's public IP), and
# prints what actually happens. Changes nothing on the server.
set -uo pipefail

CFG="/usr/local/etc/xray/config.json"
XRAY="/usr/local/bin/xray"
PUBIP="132.243.30.145"
PORT=8390
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== xray version ==="
"$XRAY" version 2>/dev/null | head -1
systemctl is-active xray

echo "=== promo inbound in live config ==="
python3 - "$CFG" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
for ib in cfg.get("inbounds", []):
    if ib.get("tag") == "ss-promo" or ib.get("port") == 8390:
        s = ib.get("settings", {})
        print("port:", ib.get("port"), "protocol:", ib.get("protocol"),
              "network:", s.get("network"))
        for c in s.get("clients", []):
            print("client email:", c.get("email"),
                  "method:", c.get("method"),
                  "password set:", bool(c.get("password")),
                  "password length:", len(c.get("password", "")))
        if "password" in s:
            print("settings-level password present, length:",
                  len(s["password"]))
print("outbounds:", [o.get("protocol") for o in cfg.get("outbounds", [])])
print("loglevel:", cfg.get("log", {}).get("loglevel"),
      "| access log:", cfg.get("log", {}).get("access"))
PYEOF

# Extract the promo password from the live config (never printed).
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
if [ -z "$PW" ]; then echo "!! no promo password found in config"; exit 1; fi

run_test() {
  local host="$1" label="$2" socks="$3"
  cat > "$TMP/client.json" <<JSON
{"log": {"loglevel": "warning"},
 "inbounds": [{"listen": "127.0.0.1", "port": $socks, "protocol": "socks",
               "settings": {"udp": true}}],
 "outbounds": [{"protocol": "shadowsocks", "tag": "proxy",
   "settings": {"servers": [{"address": "$host", "port": $PORT,
     "method": "aes-128-gcm", "password": "$PW"}]}}]}
JSON
  "$XRAY" run -config "$TMP/client.json" >"$TMP/client.log" 2>&1 &
  local pid=$!
  sleep 2
  local out
  out="$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:$socks http://api.ipify.org 2>/dev/null)"
  if [ -z "$out" ]; then
    out="$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:$socks http://ifconfig.me/ip 2>/dev/null)"
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if [ -n "$out" ]; then
    echo "$label: OK — exit IP through promo inbound = $out"
  else
    echo "$label: FAILED — no data through promo inbound"
    echo "--- client log tail ---"
    tail -5 "$TMP/client.log"
  fi
}

echo "=== end-to-end tests (server's own client) ==="
run_test "127.0.0.1" "LOOPBACK 127.0.0.1:$PORT" 11081
run_test "$PUBIP"    "PUBLIC-IP $PUBIP:$PORT" 11082

echo "=== recent xray server log (last 25 lines) ==="
journalctl -u xray --no-pager -n 25 2>/dev/null | tail -25

echo "=== firewall ==="
ufw status 2>/dev/null | head -8 || echo "ufw not present"
echo "=== DONE ==="
