#!/bin/bash
# ============================================================
# setup-hy2-anyip.sh — portable Hysteria2 server for ANY box/IP
#
# Two TLS modes (this decides which apps can use the key):
#   DOMAIN mode  : real Let's Encrypt cert via hysteria's built-in
#                  ACME -> the link works in GOLDENSKY and Aeriva
#                  (their Xray core rejects self-signed HY2).
#                  The domain's A record MUST point to this server
#                  and TCP 80 must be reachable (ACME HTTP check).
#   IP mode ("-"): self-signed cert -> link has insecure=1. Works
#                  in clients that accept insecure (official
#                  Hysteria app etc.) but NOT in GOLDENSKY/Aeriva.
#
# Usage:
#   sudo bash setup-hy2-anyip.sh <DOMAIN|-> [QUOTA_GB]
#     sudo bash setup-hy2-anyip.sh hy2.example.com        # unlimited
#     sudo bash setup-hy2-anyip.sh hy2.example.com 300    # 300 GiB cap
#     sudo bash setup-hy2-anyip.sh -                      # bare IP mode
# Env: HY2_PORT (default 8443), HY2_NAME (link name).
#
# Own unit gs-hy2-any, own config — coexists with other services.
# Re-running = RENEW (new password; quota counter reset).
# Firewall: open UDP $HY2_PORT (and TCP 80 in DOMAIN mode) in the
# provider panel if the box has one (e.g. Lightsail).
# ============================================================
set -e

DOMAIN="${1:-}"
QUOTA_GB="${2:-0}"
PORT="${HY2_PORT:-8443}"
STATS_PORT=9998
UNIT=gs-hy2-any
CFG=/etc/hysteria/config-anyip.yaml
SHARED_CONF=/etc/hysteria/anyip.conf
STATE_DIR=/var/lib/gs-hy2any
HYST_DL=https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
HYST_SHA=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691

MODE=acme
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "-" ]; then MODE=selfsigned; fi
case "$QUOTA_GB" in *[!0-9]*|'') QUOTA_GB=0 ;; esac

echo "=== Hysteria2 portable installer (mode: $MODE, port: $PORT, quota: ${QUOTA_GB}GB) ==="
[ "$(id -u)" = "0" ] || { echo "Run as root:  sudo bash setup-hy2-anyip.sh <DOMAIN|-> [QUOTA_GB]"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "-- installing python3..."; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null; }

# renew: stop our own previous instance first (frees the ports)
systemctl stop $UNIT 2>/dev/null || true
sleep 1
if ss -lun | grep -q ":${PORT}[[:space:]]"; then
  echo "!! UDP $PORT already in use by something else. Aborting (nothing changed):"
  ss -lunp | grep ":${PORT}[[:space:]]" || true
  echo "   Tip: pick another port, e.g.  HY2_PORT=8444 sudo -E bash setup-hy2-anyip.sh ..."
  exit 1
fi
if [ "$QUOTA_GB" -gt 0 ] && ss -ltn | grep -q "127.0.0.1:${STATS_PORT}[[:space:]]"; then
  echo "!! 127.0.0.1:$STATS_PORT (stats API) already in use. Aborting (nothing changed)."
  exit 1
fi

echo "-- public IP:"
PUB_IP=$(curl -s -m 10 https://api.ipify.org || curl -s -m 10 https://ifconfig.me || curl -s -m 10 https://icanhazip.com || true)
PUB_IP=$(printf '%s' "$PUB_IP" | tr -dc '0-9.')
[ -n "$PUB_IP" ] || { echo "!! Could not detect this server's public IP. Aborting."; exit 1; }
echo "   $PUB_IP"

if [ "$MODE" = "acme" ]; then
  echo "-- checking $DOMAIN points to this server..."
  HIT=$(python3 - "$DOMAIN" "$PUB_IP" <<'PYEOF'
import sys, json, urllib.request
name, ip = sys.argv[1], sys.argv[2]
try:
    req = urllib.request.Request("https://dns.google/resolve?name=%s&type=A" % name,
                                 headers={"Accept": "application/dns-json"})
    d = json.load(urllib.request.urlopen(req, timeout=10))
    ips = [a["data"] for a in d.get("Answer", []) if a.get("type") == 1]
    print("MATCH" if ip in ips else "NOMATCH:" + ",".join(ips))
except Exception as e:
    print("ERROR:%s" % e)
PYEOF
)
  case "$HIT" in
    MATCH) echo "   OK: $DOMAIN -> $PUB_IP" ;;
    NOMATCH:*) echo "!! $DOMAIN resolves to ${HIT#NOMATCH:} — not this server ($PUB_IP)."
               echo "   Point the domain's A record to $PUB_IP first, wait for DNS, then re-run. Aborting."
               exit 1 ;;
    *) echo "!! DNS check failed ($HIT) — continuing anyway; ACME will fail if the domain is wrong." ;;
  esac
  if ss -ltn | grep -q ":80[[:space:]]"; then
    echo "!! WARNING: TCP 80 is already bound (see below) — ACME HTTP check may fail."
    ss -ltnp | grep ":80[[:space:]]" || true
  fi
fi

# ---------- hysteria binary ----------
if [ -x /usr/local/bin/hysteria ]; then
  echo "-- hysteria already installed: $(/usr/local/bin/hysteria version 2>/dev/null | grep -i version | head -1)"
else
  echo "-- installing hysteria v2.13.0..."
  curl -fsSL --max-time 300 -o /tmp/hysteria "$HYST_DL"
  echo "$HYST_SHA  /tmp/hysteria" | sha256sum -c - >/dev/null
  install -m 0755 /tmp/hysteria /usr/local/bin/hysteria
  rm -f /tmp/hysteria
fi

# ---------- config ----------
PASS=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
SECRET=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
mkdir -p /etc/hysteria "$STATE_DIR"
{
  echo "listen: :$PORT"
  echo ""
  if [ "$MODE" = "acme" ]; then
    echo "acme:"
    echo "  domains:"
    echo "    - $DOMAIN"
    echo "  email: admin@$DOMAIN"
    echo "  ca: letsencrypt"
    echo "  type: http"
  else
    mkdir -p /etc/hysteria/selfsigned
    if [ ! -f /etc/hysteria/selfsigned/cert.pem ]; then
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/selfsigned/key.pem -out /etc/hysteria/selfsigned/cert.pem \
        -days 3650 -nodes -subj "/CN=$PUB_IP" \
        -addext "subjectAltName=IP:$PUB_IP" 2>/dev/null
      chmod 600 /etc/hysteria/selfsigned/key.pem
    fi
    echo "tls:"
    echo "  cert: /etc/hysteria/selfsigned/cert.pem"
    echo "  key: /etc/hysteria/selfsigned/key.pem"
  fi
  if [ "$QUOTA_GB" -gt 0 ]; then
    echo ""
    echo "trafficStats:"
    echo "  listen: 127.0.0.1:$STATS_PORT"
    echo "  secret: $SECRET"
  fi
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
} > "$CFG"
chmod 600 "$CFG"

cat > /etc/systemd/system/$UNIT.service <<EOF
[Unit]
Description=Hysteria2 (portable, $MODE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config $CFG
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable $UNIT >/dev/null 2>&1 || true
systemctl restart $UNIT

echo "-- waiting for the server to come up..."
UP=0
for i in $(seq 1 30); do
  sleep 2
  if systemctl is-active --quiet $UNIT && ss -lun | grep -q ":${PORT}[[:space:]]"; then UP=1; break; fi
done
if [ "$UP" != "1" ]; then
  echo "!! $UNIT did not come up. Last log lines:"
  journalctl -u $UNIT --no-pager -n 25
  [ "$MODE" = "acme" ] && echo "   ACME hints: $DOMAIN must point to $PUB_IP, and TCP 80 must be open in the provider firewall."
  exit 1
fi
ufw allow ${PORT}/udp >/dev/null 2>&1 || true
[ "$MODE" = "acme" ] && ufw allow 80/tcp >/dev/null 2>&1 || true
echo "OK: $UNIT running on UDP $PORT"

# ---------- optional quota guard ----------
if [ "$QUOTA_GB" -gt 0 ]; then
  echo "-- installing ${QUOTA_GB}GB quota guard..."
  cat > "$SHARED_CONF" <<EOF
SECRET=$SECRET
LIMIT_GB=$QUOTA_GB
API=http://127.0.0.1:$STATS_PORT/traffic
UNIT=$UNIT
EOF
  chmod 600 "$SHARED_CONF"
  cat > /usr/local/bin/gs-hy2any-guard.sh <<'GUARD'
#!/bin/bash
# gs-hy2any-guard — meter the portable HY2 via the hysteria Traffic Stats API.
# Sums ALL numeric values (?clear=1 deltas), accumulates into a persistent
# counter; at >= LIMIT_GB the instance is stopped. ~5 min around a restart
# may go uncounted (user's favour), same as the other promo guards.
CONF=/etc/hysteria/anyip.conf
[ -f "$CONF" ] && . "$CONF"
API=${API:-http://127.0.0.1:9998/traffic}
SECRET=${SECRET:-}
LIMIT_GB=${LIMIT_GB:-300}
UNIT=${UNIT:-gs-hy2-any}
STATE_DIR=/var/lib/gs-hy2any
TOTAL_FILE=$STATE_DIR/bytes
STATUS=/root/hy2-any-usage.txt
mkdir -p "$STATE_DIR"
[ -f "$TOTAL_FILE" ] || echo 0 > "$TOTAL_FILE"
TOTAL=$(tr -dc '0-9' < "$TOTAL_FILE"); [ -n "$TOTAL" ] || TOTAL=0

fetch() { curl -s -m 10 -H "Authorization: $1" "$API?clear=1"; }
RESP=$(fetch "$SECRET")
case "$RESP" in *{*) ;; *) RESP=$(fetch "Bearer $SECRET");; esac
DELTA=$(printf '%s' "$RESP" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    def s(o):
        if isinstance(o, dict): return sum(s(v) for v in o.values())
        if isinstance(o, (int, float)): return int(o)
        return 0
    print(s(d))
except Exception:
    print(-1)' 2>/dev/null)
if [ -n "$DELTA" ] && [ "$DELTA" -ge 0 ] 2>/dev/null; then
  TOTAL=$((TOTAL + DELTA))
  echo "$TOTAL" > "$TOTAL_FILE.tmp" && mv "$TOTAL_FILE.tmp" "$TOTAL_FILE"
fi

LIMIT=$((LIMIT_GB * 1024 * 1024 * 1024))
USED=$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t/1073741824}')
LEFT=$(awk -v t="$TOTAL" -v l="$LIMIT" 'BEGIN{d=l-t; if(d<0)d=0; printf "%.2f", d/1073741824}')
if [ "$TOTAL" -ge "$LIMIT" ]; then
  systemctl stop "$UNIT" 2>/dev/null || true
  STATE="EXHAUSTED — service stopped at ${LIMIT_GB}GB. Re-run setup-hy2-anyip.sh to renew."
else
  STATE="ACTIVE"
fi
{
  echo "HY2 (portable) usage"
  echo "  Used : ${USED} GiB / ${LIMIT_GB} GiB"
  echo "  Left : ${LEFT} GiB"
  echo "  State: $STATE"
  echo "  Updated: $(date -u '+%F %T UTC')"
} > "$STATUS"
GUARD
  chmod +x /usr/local/bin/gs-hy2any-guard.sh
  cat > /etc/cron.d/gs-hy2any-guard <<'EOF'
*/5 * * * * root /usr/local/bin/gs-hy2any-guard.sh >/dev/null 2>&1
EOF
  echo 0 > "$STATE_DIR/bytes"
  /usr/local/bin/gs-hy2any-guard.sh || true
  TEST=$(curl -s -m 10 -H "Authorization: $SECRET" "http://127.0.0.1:$STATS_PORT/traffic" || true)
  case "$TEST" in
    *{*) echo "OK: traffic stats API answers" ;;
    *) echo "WARNING: stats API did not answer (got: $TEST) — the key works, but quota metering may not count." ;;
  esac
fi

# ---------- link ----------
if [ -n "${HY2_NAME:-}" ]; then NAME="$HY2_NAME";
elif [ "$QUOTA_GB" -gt 0 ]; then NAME="HY2-FREE-${QUOTA_GB}GB";
else NAME="HY2"; fi
if [ "$MODE" = "acme" ]; then
  LINK="hy2://${PASS}@${DOMAIN}:${PORT}?sni=${DOMAIN}#${NAME}"
else
  LINK="hy2://${PASS}@${PUB_IP}:${PORT}?insecure=1&sni=${PUB_IP}#${NAME}"
fi
echo "$LINK" > /root/my-hy2-anyip.txt
chmod 600 /root/my-hy2-anyip.txt
echo ""
echo "==========================================================="
echo "DONE: HY2 is live ($MODE mode)"
echo ""
echo "Link:"
echo "$LINK"
echo ""
echo "  Port    : $PORT/udp — open it in the provider firewall if the box has one (Lightsail!)"
[ "$MODE" = "acme" ] && echo "  ACME    : also keep TCP 80 open (certificate issuing/renewal)"
[ "$QUOTA_GB" -gt 0 ] && echo "  Quota   : $QUOTA_GB GiB total, auto-stop by guard (cron 5 min); usage: cat /root/hy2-any-usage.txt"
echo "  Renew   : re-run this script (new password; quota counter reset)"
if [ "$MODE" = "selfsigned" ]; then
  echo ""
  echo "  !! IP MODE: this link uses a self-signed cert (insecure=1)."
  echo "     GOLDENSKY / Aeriva will NOT accept it. For those apps use"
  echo "     DOMAIN mode:  sudo bash setup-hy2-anyip.sh <your-domain>"
fi
echo "==========================================================="
