#!/bin/bash
# ============================================================
# fix-hy2-sg.sh — stage-2 fix for the portable HY2 kit install
# (gs-hy2-any) when ACME is stuck: the built-in ACME http
# challenge needs TCP 80 and the tls challenge needs TCP 443,
# and BOTH are already bound by other services on this box,
# so hysteria never got a certificate and never opened its
# QUIC listener (clients see a silent timeout).
#
# What this script does:
#   1. Reports who owns TCP 80 / TCP 443 (name + cmdline).
#      REPORT ONLY — it never kills or stops anything.
#   2. Hunts the box for an EXISTING certificate that covers
#      the HY2 domain (Let's Encrypt, Caddy, acme.sh, x-ui,
#      certmagic leftovers), checking SAN + expiry.
#   3. If a valid cert+key pair is found: backs up the
#      hysteria config, replaces the acme: block with a
#      tls: cert/key block (the "Tokyo pattern" — certbot/
#      Caddy own the cert, hysteria just uses the files),
#      restarts the unit, and re-runs the on-box end-to-end
#      client test with REAL verification (insecure=false).
#      On failure the backup is restored automatically.
#   4. If no usable cert exists, prints the owners' full
#      cmdlines at the END (screenshot-friendly) so the next
#      step can be decided with full information.
#
# Usage:  sudo bash fix-hy2-sg.sh
# ============================================================

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash fix-hy2-sg.sh"
  exit 1
fi

UNIT=gs-hy2-any
CFG=/etc/hysteria/config-anyip.yaml
LINKFILE=/root/my-hy2-anyip.txt
BIN=/usr/local/bin/hysteria

ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; }
note() { echo "  [..]   $*"; }
hr()   { echo "------------------------------------------------------------"; }

echo "============================================================"
echo " HY2 stage-2 fix — $UNIT"
echo "============================================================"

[ -x "$BIN" ] || { echo "FATAL: $BIN not found — portable HY2 kit is not installed here."; exit 1; }
[ -f "$CFG" ] || { echo "FATAL: $CFG not found."; exit 1; }
[ -f "$LINKFILE" ] || { echo "FATAL: $LINKFILE not found."; exit 1; }

LINK=$(cat "$LINKFILE")
PASS=$(printf '%s' "$LINK" | sed -n 's#.*://\([^@]*\)@.*#\1#p')
DOMAIN=$(printf '%s' "$LINK" | sed -n 's#.*@\([^:/?]*\).*#\1#p')
PORT=$(awk '/^listen:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$CFG")
[ -n "$PORT" ] || PORT=8443
[ -n "$PASS" ] && [ -n "$DOMAIN" ] || { echo "FATAL: could not parse link file."; exit 1; }
note "domain=$DOMAIN port=$PORT/udp"

# ---------- 1) service + listener + port owners ----------
hr; echo "1) Service, listener, and who owns TCP 80 / 443"
if systemctl is-active --quiet $UNIT; then
  ok "$UNIT is active"
else
  note "$UNIT not active — restarting it..."
  systemctl restart $UNIT 2>/dev/null; sleep 4
  systemctl is-active --quiet $UNIT && ok "$UNIT active after restart" || bad "$UNIT still not active"
fi
if ss -lunp 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
  ok "UDP $PORT is listening: $(ss -lunp 2>/dev/null | grep ":${PORT}[[:space:]]" | head -1 | sed 's/^ *//')"
else
  bad "UDP $PORT is NOT listening — the server cannot answer any client"
fi
owner_of() {  # $1 = tcp port
  local line pid
  line=$(ss -tlnp 2>/dev/null | grep ":$1[[:space:]]" | head -1)
  [ -n "$line" ] || { echo "free"; return; }
  pid=$(printf '%s' "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
  if [ -n "$pid" ]; then
    echo "pid $pid ($(cat /proc/$pid/comm 2>/dev/null)): $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-140)"
  else
    echo "$line" | sed 's/^ *//' | cut -c1-160
  fi
}
OWN80=$(owner_of 80)
OWN443=$(owner_of 443)
note "TCP 80  owner: $OWN80"
note "TCP 443 owner: $OWN443"
note "last journal lines for $UNIT:"
journalctl -u $UNIT --no-pager -n 12 -o cat 2>/dev/null | sed 's/^/    /'

# ---------- 2) certificate hunt ----------
hr; echo "2) Hunting for an existing certificate covering $DOMAIN"
FOUND_CERT=""; FOUND_KEY=""
cert_covers() {  # $1 = cert pem; prints expiry if it covers DOMAIN and is valid
  local crt="$1" sans
  [ -f "$crt" ] || return 1
  sans=$(openssl x509 -noout -ext subjectAltName -in "$crt" 2>/dev/null)
  [ -n "$sans" ] || sans=$(openssl x509 -noout -text -in "$crt" 2>/dev/null | grep -A1 'Subject Alternative Name')
  printf '%s' "$sans" | grep -q "DNS:${DOMAIN}\b" || return 1
  openssl x509 -noout -checkend 0 -in "$crt" >/dev/null 2>&1 || return 1
  openssl x509 -noout -enddate -in "$crt" 2>/dev/null | cut -d= -f2
}
# Candidate fullchain files, most trustworthy first.
CANDIDATES=""
for d in /etc/letsencrypt/live/*/fullchain.pem \
         /acme/certificates/*/*/$DOMAIN/$DOMAIN.crt \
         /var/lib/caddy/certificates/*/*/$DOMAIN/$DOMAIN.crt \
         /root/.local/share/caddy/certificates/*/*/$DOMAIN/$DOMAIN.crt \
         /root/.acme.sh/$DOMAIN/fullchain.cer \
         /root/.acme.sh/${DOMAIN}_ecc/fullchain.cer; do
  [ -f "$d" ] && CANDIDATES="$CANDIDATES $d"
done
# Plus a bounded find for anything cert-like named after the domain.
EXTRA=$(timeout 30 find /etc /root /home /var/lib /acme /usr/local -name "*${DOMAIN}*.crt" -o -name "*${DOMAIN}*.pem" 2>/dev/null | grep -v config-anyip | head -10)
for f in $EXTRA; do case " $CANDIDATES " in *" $f "*) ;; *) CANDIDATES="$CANDIDATES $f";; esac; done

for CRT in $CANDIDATES; do
  EXP=$(cert_covers "$CRT") || continue
  DIR=$(dirname "$CRT")
  KEY=""
  for k in "$DIR/privkey.pem" "$DIR/$DOMAIN.key" "$DIR/key.pem" \
           "/root/.acme.sh/$DOMAIN/$DOMAIN.key" "/root/.acme.sh/${DOMAIN}_ecc/$DOMAIN.key" \
           "${CRT%.crt}.key" "${CRT%fullchain.pem}privkey.pem" "${CRT%fullchain.cer}key.pem"; do
    [ -f "$k" ] && { KEY="$k"; break; }
  done
  if [ -n "$KEY" ]; then
    ok "usable cert found: $CRT (valid until $EXP)"
    note "key: $KEY"
    FOUND_CERT="$CRT"; FOUND_KEY="$KEY"
    break
  else
    note "cert covers $DOMAIN but no matching key file found next to it: $CRT"
  fi
done
[ -n "$FOUND_CERT" ] || note "no usable on-box certificate found for $DOMAIN"

# ---------- client test (same method as the check script) ----------
client_test() {
  local CYML VLOG VPID VIA i
  CYML=$(mktemp /tmp/hy2fix-XXXXXX.yaml); chmod 600 "$CYML"
  VLOG=$(mktemp /tmp/hy2fix-XXXXXX.log)
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
  VIA=$(curl -s -m 15 --socks5-hostname 127.0.0.1:11081 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
  kill $VPID 2>/dev/null; wait $VPID 2>/dev/null
  if [ -n "$VIA" ]; then
    note "via-HY2 exit IP: $VIA"
    rm -f "$CYML" "$VLOG"
    return 0
  fi
  note "client test log tail:"
  grep -iE 'fatal|error|fail|certificate|auth' "$VLOG" 2>/dev/null | tail -4 | sed 's/^/    /'
  rm -f "$CYML" "$VLOG"
  return 1
}

# ---------- 3) apply the cert if one was found ----------
FIXED=0
if [ -n "$FOUND_CERT" ]; then
  hr; echo "3) Wiring the found certificate into the hysteria config"
  cp "$CFG" "$CFG.bak-fix2"
  # Rebuild the config from the kit's template, preserving port +
  # password (+ trafficStats block if the original had one).
  STATS_BLOCK=$(awk '/^trafficStats:/{f=1} f&&/^$/{exit} f{print}' "$CFG")
  {
    echo "listen: :$PORT"
    echo ""
    echo "tls:"
    echo "  cert: $FOUND_CERT"
    echo "  key: $FOUND_KEY"
    if [ -n "$STATS_BLOCK" ]; then echo ""; printf '%s\n' "$STATS_BLOCK"; fi
    echo ""
    echo "auth:"
    echo "  type: password"
    echo "  password: $PASS"
    echo ""
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: https://www.bing.com"
    echo "    rewriteHost: true"
  } > "$CFG.new" && mv "$CFG.new" "$CFG"
  note "config rewritten (backup: $CFG.bak-fix2) — restarting..."
  systemctl restart $UNIT; sleep 5
  if systemctl is-active --quiet $UNIT && ss -lun 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
    note "server is up and listening — running the end-to-end test..."
    for w in 0 15 15; do
      [ "$w" != "0" ] && { note "retrying after ${w}s..."; sleep $w; }
      if client_test; then FIXED=1; break; fi
    done
  else
    note "server did not come up cleanly with the new config"
  fi
  if [ "$FIXED" = "1" ]; then
    ok "FIXED — the key now works with real certificate verification."
    rm -f "$CFG.bak-fix2"
  else
    note "fix did not pass — restoring the original config"
    mv "$CFG.bak-fix2" "$CFG"
    systemctl restart $UNIT; sleep 3
    bad "cert wiring failed (original config restored)"
  fi
fi

# ---------- summary (verdict LAST, screenshot-friendly) ----------
hr
echo "============================================================"
if [ "$FIXED" = "1" ]; then
  echo " SUMMARY: FIXED"
  echo " The SG HY2 server now answers with a real certificate."
  echo " Test the SAME link on the phone (Aeriva 117 / GOLDENSKY /"
  echo " v2rayNG): My IP must read this box's public IP."
  echo " NOTE: the certificate belongs to another service on this"
  echo " box; when that service renews it (~every 60-90 days),"
  echo " restart $UNIT once to pick the new files up:"
  echo "   sudo systemctl restart $UNIT"
else
  echo " SUMMARY: NOT FIXED YET — information gathered above."
  echo " TCP 80  owner: $OWN80"
  echo " TCP 443 owner: $OWN443"
  if [ -z "$FOUND_CERT" ]; then
    echo " No usable certificate for $DOMAIN exists on this box,"
    echo " and ACME cannot use ports 80/443 while the owners above"
    echo " hold them. Options (decide from the owners printed):"
    echo "   a) If the :80 process is a leftover test process, stop"
    echo "      it and re-run the original kit — ACME http will work."
    echo "   b) Use a DNS challenge (needs a Cloudflare API token)."
    echo " Send a screenshot of this whole output."
  else
    echo " A certificate was found but wiring it in did not pass"
    echo " the client test; the original config was restored."
    echo " Send a screenshot of this whole output."
  fi
fi
echo ""
echo " Current link (from $LINKFILE):"
echo " $LINK"
echo "============================================================"
