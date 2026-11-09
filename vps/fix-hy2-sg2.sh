#!/bin/bash
# ============================================================
# fix-hy2-sg2.sh — stage-3 fix for the SG portable HY2 install.
#
# Established facts (from check-hy2-anyip.sh + fix-hy2-sg.sh):
#   * gs-hy2-any has NO certificate: its built-in ACME cannot
#     run — the http challenge needs TCP 80 (held by the
#     ssh-ws-bridge) and the tls challenge needs TCP 443
#     (held by Caddy). Without a cert the QUIC listener never
#     opens, so every client sees a silent timeout.
#   * No existing cert for the domain is anywhere on the box.
#   * Caddy owns TCP 443 and is itself an ACME client: it can
#     issue via TLS-ALPN on its own port.
#
# This script (nothing is killed or stopped):
#   1. Backs up /etc/caddy/Caddyfile and appends a minimal
#      site block for the HY2 domain (validates first, then
#      a graceful `caddy reload` — existing sites untouched).
#   2. Waits for Caddy to issue a real Let's Encrypt cert.
#   3. Wires that cert into the hysteria config (the acme:
#      block is replaced by tls: cert/key — the pattern the
#      Marzban box uses), restarts gs-hy2-any, and re-runs
#      the on-box end-to-end client test with REAL cert
#      verification (insecure=false).
#   4. Any failure restores BOTH backups (Caddyfile only if
#      this script changed it and no cert was issued;
#      hysteria config always on a failed test).
#
# Usage:  sudo bash fix-hy2-sg2.sh
# ============================================================

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash fix-hy2-sg2.sh"
  exit 1
fi

UNIT=gs-hy2-any
CFG=/etc/hysteria/config-anyip.yaml
LINKFILE=/root/my-hy2-anyip.txt
BIN=/usr/local/bin/hysteria
CADDY=/usr/local/bin/caddy
CADDYFILE=/etc/caddy/Caddyfile

ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; }
note() { echo "  [..]   $*"; }
hr()   { echo "------------------------------------------------------------"; }

echo "============================================================"
echo " HY2 stage-3 fix — let Caddy issue the cert"
echo "============================================================"

[ -x "$BIN" ] || { echo "FATAL: $BIN not found."; exit 1; }
[ -x "$CADDY" ] || { echo "FATAL: $CADDY not found."; exit 1; }
[ -f "$CFG" ] || { echo "FATAL: $CFG not found."; exit 1; }
[ -f "$CADDYFILE" ] || { echo "FATAL: $CADDYFILE not found."; exit 1; }
[ -f "$LINKFILE" ] || { echo "FATAL: $LINKFILE not found."; exit 1; }

LINK=$(cat "$LINKFILE")
PASS=$(printf '%s' "$LINK" | sed -n 's#.*://\([^@]*\)@.*#\1#p')
DOMAIN=$(printf '%s' "$LINK" | sed -n 's#.*@\([^:/?]*\).*#\1#p')
PORT=$(awk '/^listen:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$CFG")
[ -n "$PORT" ] || PORT=8443
[ -n "$PASS" ] && [ -n "$DOMAIN" ] || { echo "FATAL: could not parse link file."; exit 1; }
note "domain=$DOMAIN port=$PORT/udp"

cert_covers() {  # $1 = cert pem; prints expiry if it covers DOMAIN and is currently valid
  local crt="$1" sans
  [ -f "$crt" ] || return 1
  sans=$(openssl x509 -noout -ext subjectAltName -in "$crt" 2>/dev/null)
  [ -n "$sans" ] || sans=$(openssl x509 -noout -text -in "$crt" 2>/dev/null | grep -A1 'Subject Alternative Name')
  printf '%s' "$sans" | grep -q "DNS:${DOMAIN}\b" || return 1
  openssl x509 -noout -checkend 0 -in "$crt" >/dev/null 2>&1 || return 1
  openssl x509 -noout -enddate -in "$crt" 2>/dev/null | cut -d= -f2
}
find_cert() {  # echoes "cert key" for the first usable pair, or nothing
  local CRT DIR KEY EXP
  for CRT in $(timeout 40 find /var/lib/caddy /root/.local/share/caddy /acme /etc/letsencrypt \
                 -name "$DOMAIN.crt" -o -name "fullchain.pem" -o -name "fullchain.cer" 2>/dev/null | head -20); do
    EXP=$(cert_covers "$CRT") || continue
    DIR=$(dirname "$CRT")
    KEY=""
    for k in "$DIR/$DOMAIN.key" "$DIR/privkey.pem" "$DIR/key.pem"; do
      [ -f "$k" ] && { KEY="$k"; break; }
    done
    [ -n "$KEY" ] && { echo "$CRT $KEY"; return 0; }
  done
  return 1
}

# ---------- 1) Caddy site for the domain ----------
hr; echo "1) Caddy: make sure it serves (and certifies) $DOMAIN"
CADDY_CHANGED=0
CERTPAIR=$(find_cert)
if [ -n "$CERTPAIR" ]; then
  ok "a usable cert already exists: $CERTPAIR"
else
  if grep -qE "(^|[[:space:],])${DOMAIN}([[:space:],{]|$)" "$CADDYFILE"; then
    note "Caddyfile already has a site for $DOMAIN — no change needed"
  else
    cp "$CADDYFILE" "$CADDYFILE.bak-hy2fix"
    {
      echo ""
      echo "$DOMAIN {"
      echo "	respond \"ok\" 200"
      echo "}"
    } >> "$CADDYFILE"
    if "$CADDY" validate --config "$CADDYFILE" >/dev/null 2>&1; then
      ok "site block appended and Caddyfile validates"
      CADDY_CHANGED=1
    else
      bad "Caddyfile with the new block does NOT validate — restoring"
      mv "$CADDYFILE.bak-hy2fix" "$CADDYFILE"
      echo "FATAL: cannot proceed. Send a screenshot of this output."
      exit 1
    fi
  fi
  if [ "$CADDY_CHANGED" = "1" ] || grep -qE "(^|[[:space:],])${DOMAIN}([[:space:],{]|$)" "$CADDYFILE"; then
    note "graceful reload..."
    if "$CADDY" reload --config "$CADDYFILE" >/dev/null 2>&1 || systemctl reload caddy >/dev/null 2>&1; then
      ok "Caddy reloaded (existing sites untouched)"
    else
      note "graceful reload failed — NOT forcing a restart. Recent Caddy journal:"
      journalctl -u caddy --no-pager -n 10 -o cat 2>/dev/null | sed 's/^/    /'
      [ "$CADDY_CHANGED" = "1" ] && { mv "$CADDYFILE.bak-hy2fix" "$CADDYFILE"; note "Caddyfile change rolled back"; }
      echo "FATAL: reload failed. Send a screenshot of this output."
      exit 1
    fi
  fi
  note "waiting for Caddy to issue the certificate (up to ~2 min)..."
  for i in $(seq 1 12); do
    CERTPAIR=$(find_cert)
    [ -n "$CERTPAIR" ] && break
    sleep 10
  done
  if [ -n "$CERTPAIR" ]; then
    ok "certificate issued: $CERTPAIR"
  else
    bad "no certificate appeared after ~2 minutes"
    note "recent Caddy journal (acme/cert lines):"
    journalctl -u caddy --no-pager -n 200 -o cat 2>/dev/null | grep -iE 'acme|certificate|obtain|challenge|error' | tail -8 | sed 's/^/    /'
    if [ "$CADDY_CHANGED" = "1" ]; then
      mv "$CADDYFILE.bak-hy2fix" "$CADDYFILE"
      "$CADDY" reload --config "$CADDYFILE" >/dev/null 2>&1 || systemctl reload caddy >/dev/null 2>&1
      note "Caddyfile change rolled back (site block removed again)"
    fi
    echo "============================================================"
    echo " SUMMARY: NOT FIXED — Caddy could not issue the cert."
    echo " The journal lines above say why (usually DNS or the"
    echo " challenge being blocked). Send a screenshot."
    echo "============================================================"
    exit 1
  fi
fi
CRT=${CERTPAIR%% *}; KEY=${CERTPAIR#* }
EXP=$(cert_covers "$CRT")

# ---------- 2) wire the cert into hysteria ----------
hr; echo "2) Wiring the certificate into the hysteria config"
cp "$CFG" "$CFG.bak-fix3"
STATS_BLOCK=$(awk '/^trafficStats:/{f=1} f&&/^$/{exit} f{print}' "$CFG")
{
  echo "listen: :$PORT"
  echo ""
  echo "tls:"
  echo "  cert: $CRT"
  echo "  key: $KEY"
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
note "config rewritten (backup: $CFG.bak-fix3) — restarting $UNIT..."
systemctl restart $UNIT; sleep 5

client_test() {
  local CYML VLOG VPID VIA i
  CYML=$(mktemp /tmp/hy2fix3-XXXXXX.yaml); chmod 600 "$CYML"
  VLOG=$(mktemp /tmp/hy2fix3-XXXXXX.log)
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

FIXED=0
if systemctl is-active --quiet $UNIT && ss -lun 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
  ok "$UNIT is up and listening on UDP $PORT"
  for w in 0 15 15; do
    [ "$w" != "0" ] && { note "retrying after ${w}s..."; sleep $w; }
    if client_test; then FIXED=1; break; fi
  done
else
  bad "$UNIT did not come up with the new config"
  note "journal tail:"
  journalctl -u $UNIT --no-pager -n 8 -o cat 2>/dev/null | sed 's/^/    /'
fi

if [ "$FIXED" = "1" ]; then
  rm -f "$CFG.bak-fix3" "$CADDYFILE.bak-hy2fix"
else
  note "restoring the original hysteria config"
  mv "$CFG.bak-fix3" "$CFG"
  systemctl restart $UNIT; sleep 3
fi

# ---------- summary ----------
hr
echo "============================================================"
if [ "$FIXED" = "1" ]; then
  echo " SUMMARY: FIXED"
  echo " Caddy issued a real cert for $DOMAIN (valid until $EXP)"
  echo " and $UNIT now serves it — the on-box test passed with"
  echo " REAL certificate verification."
  echo " Test the SAME link on the phone now: My IP must read"
  echo " this box's public IP (47.129.129.29)."
  echo " HOUSEKEEPING: Caddy renews the cert by itself; $UNIT"
  echo " reads the files at startup, so after a renewal it needs"
  echo " one restart:  sudo systemctl restart $UNIT"
  echo " (If phone fails while this box test passed, open UDP"
  echo " $PORT in the Lightsail firewall — that is the last gate.)"
else
  echo " SUMMARY: NOT FIXED — the hysteria side did not pass."
  echo " The Caddy site block + certificate are in place; the"
  echo " original hysteria config was restored. Send a"
  echo " screenshot of this whole output."
fi
echo ""
echo " Current link (from $LINKFILE):"
echo " $LINK"
echo "============================================================"
