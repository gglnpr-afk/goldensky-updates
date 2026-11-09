#!/bin/bash
# ============================================================
# check-hy2-anyip.sh — definitive server-side check (+ one
# safe cert fix) for portable HY2 kit installs (gs-hy2-any).
#
# Checks, in order:
#   1. service active + UDP port listening
#   2. ACME certificate evidence + journal scan
#   3. who holds TCP 80 (report only — may be a live service,
#      it is NEVER killed by this script)
#   4. END-TO-END test: a real hysteria client on this box
#      connects to the server with REAL cert verification
#      (insecure=false) and pulls a page through it. PASS =
#      cert + password + server + egress all proven.
#   5. If the test fails and the config pins ACME to
#      "type: http" while TCP 443 is free, it switches ACME
#      to "type: tls" (TLS-ALPN challenge on 443), restarts,
#      and re-tests. Backup is restored if the fix fails.
#
# Usage:  sudo bash check-hy2-anyip.sh
# ============================================================

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash check-hy2-anyip.sh"
  exit 1
fi

UNIT=gs-hy2-any
CFG=/etc/hysteria/config-anyip.yaml
LINKFILE=/root/my-hy2-anyip.txt
BIN=/usr/local/bin/hysteria
FAILS=0

ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS+1)); }
note() { echo "  [..]   $*"; }
hr()   { echo "------------------------------------------------------------"; }

echo "============================================================"
echo " HY2 server check — $UNIT"
echo "============================================================"

[ -x "$BIN" ] || { echo "FATAL: $BIN not found — portable HY2 kit is not installed on this box."; exit 1; }
[ -f "$CFG" ] || { echo "FATAL: $CFG not found."; exit 1; }
[ -f "$LINKFILE" ] || { echo "FATAL: $LINKFILE not found (kit saves the link there)."; exit 1; }

LINK=$(cat "$LINKFILE")
PASS=$(printf '%s' "$LINK" | sed -n 's#.*://\([^@]*\)@.*#\1#p')
DOMAIN=$(printf '%s' "$LINK" | sed -n 's#.*@\([^:/?]*\).*#\1#p')
PORT=$(awk '/^listen:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$CFG")
[ -n "$PORT" ] || PORT=8443
[ -n "$PASS" ] && [ -n "$DOMAIN" ] || { echo "FATAL: could not parse link file."; exit 1; }
note "domain=$DOMAIN port=$PORT/udp"

hr; echo "1) Service"
if systemctl is-active --quiet $UNIT; then
  ok "$UNIT is active"
else
  note "$UNIT not active — restarting it..."
  systemctl restart $UNIT 2>/dev/null; sleep 4
  systemctl is-active --quiet $UNIT && ok "$UNIT active after restart" || bad "$UNIT still not active (journal at the end)"
fi
if ss -lun | grep -q ":${PORT}[[:space:]]"; then
  ok "UDP $PORT is listening"
else
  bad "UDP $PORT is NOT listening"
fi

hr; echo "2) Certificate evidence"
CRT=$(timeout 30 find /acme /root /home /var/lib /etc -name "$DOMAIN.crt" -path "*certmagic*" 2>/dev/null | head -1)
if [ -n "$CRT" ]; then
  END=$(openssl x509 -noout -enddate -in "$CRT" 2>/dev/null | cut -d= -f2)
  if openssl x509 -noout -checkend 0 -in "$CRT" >/dev/null 2>&1; then
    ok "ACME cert found, valid until: $END"
  else
    bad "ACME cert found but EXPIRED ($END)"
  fi
else
  note "cert file not found on disk — the client test below is the real verdict"
fi
note "recent acme/cert/error journal lines:"
journalctl -u $UNIT --no-pager -n 150 -o cat 2>/dev/null | grep -iE 'acme|certificate|obtain|error|fail' | tail -8 | sed 's/^/    /'
echo "    (end of journal scan)"

hr; echo "3) TCP 80 holder (report only — never killed by this script)"
H80=$(ss -tlnp 2>/dev/null | grep ':80[[:space:]]' | head -1)
if [ -n "$H80" ]; then
  note "TCP 80 is bound: $H80"
else
  note "TCP 80 is free"
fi
if ss -tln 2>/dev/null | grep -q ':443[[:space:]]'; then
  note "TCP 443 is bound (TLS-ALPN fix unavailable if needed)"
  TCP443_FREE=0
else
  note "TCP 443 is free"
  TCP443_FREE=1
fi

client_test() {
  local CYML VLOG VPID VIA DIRECT i
  CYML=$(mktemp /tmp/hy2check-XXXXXX.yaml); chmod 600 "$CYML"
  VLOG=$(mktemp /tmp/hy2check-XXXXXX.log)
  cat > "$CYML" <<EOF
server: 127.0.0.1:$PORT
auth: $PASS
tls:
  sni: $DOMAIN
  insecure: false
socks5:
  listen: 127.0.0.1:11081
EOF
  "$BIN" client --config "$CYML" > "$VLOG" 2>&1 &
  VPID=$!
  for i in $(seq 1 12); do
    ss -tln 2>/dev/null | grep -q ':11081[[:space:]]' && break
    kill -0 $VPID 2>/dev/null || break
    sleep 1
  done
  DIRECT=$(curl -s -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
  VIA=$(curl -s -m 15 --socks5-hostname 127.0.0.1:11081 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
  kill $VPID 2>/dev/null; wait $VPID 2>/dev/null
  if [ -n "$VIA" ]; then
    note "direct exit IP: ${DIRECT:-?} / via-HY2 exit IP: $VIA"
    rm -f "$CYML" "$VLOG"
    return 0
  fi
  note "client could not pull traffic through the server. Client log:"
  grep -iE 'fatal|error|fail|certificate|auth' "$VLOG" 2>/dev/null | tail -5 | sed 's/^/    /'
  rm -f "$CYML" "$VLOG"
  return 1
}

hr; echo "4) End-to-end client test (real cert verification)"
if client_test; then
  ok "PASS — cert + password + server + traffic all proven on this box"
  PROVEN=1
else
  bad "end-to-end test FAILED"
  PROVEN=0
fi

if [ "$PROVEN" = "0" ] && grep -q '^  type: http$' "$CFG"; then
  hr; echo "5) Cert fix attempt — ACME http -> tls challenge"
  if [ "$TCP443_FREE" = "1" ]; then
    cp "$CFG" "$CFG.bak-checkfix"
    sed -i 's/^  type: http$/  type: tls/' "$CFG"
    note "config switched to type: tls — restarting (issuance can take ~1 min)..."
    systemctl restart $UNIT; sleep 5
    FIXED=0
    for w in 20 25 30; do
      sleep $w
      if client_test; then FIXED=1; break; fi
      note "not yet — waiting for ACME issuance..."
    done
    if [ "$FIXED" = "1" ]; then
      ok "FIXED — cert issued via TLS-ALPN (TCP 443). Keep TCP 443 AND UDP $PORT open in the provider firewall for renewals."
      PROVEN=1; FAILS=$((FAILS-1))
      rm -f "$CFG.bak-checkfix"
    else
      note "fix did not work — restoring the original config"
      mv "$CFG.bak-checkfix" "$CFG"
      systemctl restart $UNIT; sleep 3
      bad "cert fix failed (original config restored). Blocker: ACME needs port 80 (held, see step 3) or port 443 reachable from the internet."
    fi
  else
    bad "cannot try the TLS challenge: TCP 443 is also bound. ACME is stuck until port 80's owner or a DNS challenge is used."
  fi
fi

hr; echo "6) Local firewall (ufw)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if ufw status 2>/dev/null | grep -q "${PORT}/udp"; then
    ok "ufw already allows UDP $PORT"
  else
    ufw allow ${PORT}/udp >/dev/null 2>&1 && ok "ufw: allowed UDP $PORT (added by this check)" || note "ufw rule add failed — check manually"
  fi
else
  note "ufw not active — nothing to do (provider firewall is separate, see summary)"
fi

hr
echo "============================================================"
if [ "$PROVEN" = "1" ]; then
  echo " SUMMARY: SERVER SIDE = PASS"
  echo " Cert, password, server and real traffic are all proven ON"
  echo " this box. If the phone still cannot use the key, the block"
  echo " is outside the box:"
  echo "   1. Provider firewall (Lightsail): open UDP $PORT inbound."
  echo "   2. If that is open and it still fails, the carrier path"
  echo "      may be killing plain QUIC — the obfs (STRONG) design"
  echo "      is the answer for that path."
else
  echo " SUMMARY: SERVER SIDE = FAIL ($FAILS problem area(s) above)"
  echo " Send a screenshot of this whole output for the next fix."
fi
echo ""
echo " Current link (from $LINKFILE):"
echo " $LINK"
echo "============================================================"
