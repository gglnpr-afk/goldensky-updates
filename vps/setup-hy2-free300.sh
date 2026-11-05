#!/bin/bash
# ============================================================
# setup-hy2-free300.sh — HY2-FREE-300GB for GOLDENSKY/Aeriva
#
# Adds a SEPARATE Hysteria2 instance on the SAME box as the
# existing GOLDENSKY-HY2 (busterzone.mobi, Lightsail Tokyo):
#   - own UDP port 8445, own password, own systemd unit
#   - the main HY2 (:8443, unit "hysteria") is NOT touched
#   - traffic is metered via the hysteria Traffic Stats API
#     by a cron guard; at >= 300 GiB total the instance stops
#   - re-running this script = RENEW (new password, counter reset)
#
# Usage:  sudo bash setup-hy2-free300.sh
# Needs:  the main GOLDENSKY-HY2 install on this box
#         (/usr/local/bin/hysteria + /etc/hysteria/config.yaml)
# NOTE:   open UDP 8445 in the Lightsail firewall too!
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash setup-hy2-free300.sh"
  exit 1
fi

FREE_PORT=8445
STATS_PORT=9999
LIMIT_GB=300
UNIT=gs-hy2free
MAIN_CFG=/etc/hysteria/config.yaml
FREE_CFG=/etc/hysteria/config-free300.yaml
SHARED_CONF=/etc/hysteria/free300.conf
STATE_DIR=/var/lib/gs-hy2free

echo "== 1/6 check main HY2 install =="
[ -x /usr/local/bin/hysteria ] || { echo "ERROR: /usr/local/bin/hysteria not found — run this on the box with GOLDENSKY-HY2 (busterzone)."; exit 1; }
[ -f "$MAIN_CFG" ] || { echo "ERROR: $MAIN_CFG not found — main HY2 config missing."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "installing python3 (guard needs it)..."; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null; }
echo "OK: $(hysteria version 2>/dev/null | head -1)"

echo "== 2/6 reuse domain + cert from main config =="
CERT=$(awk '/^[[:space:]]*cert:/{print $2; exit}' "$MAIN_CFG")
KEY=$(awk '/^[[:space:]]*key:/{print $2; exit}' "$MAIN_CFG")
DOMAIN=$(printf '%s' "$CERT" | sed -n 's#.*/live/\([^/]*\)/.*#\1#p')
[ -n "$CERT" ] && [ -f "$CERT" ] || { echo "ERROR: cannot read cert path from main config (got: $CERT)"; exit 1; }
[ -n "$KEY" ] && [ -f "$KEY" ] || { echo "ERROR: cannot read key path from main config (got: $KEY)"; exit 1; }
[ -n "$DOMAIN" ] || DOMAIN=busterzone.mobi
echo "OK: domain=$DOMAIN cert=$CERT"

echo "== 3/6 port checks =="
if ss -lun | grep -q ":${FREE_PORT}[[:space:]]"; then
  if systemctl is-active --quiet $UNIT; then
    echo "UDP $FREE_PORT is our own $UNIT (renew run) — OK"
  else
    echo "ERROR: UDP $FREE_PORT already in use by something else. Aborting, nothing changed."
    exit 1
  fi
fi
if ss -ltn | grep -q "127.0.0.1:${STATS_PORT}[[:space:]]" && ! systemctl is-active --quiet $UNIT; then
  echo "ERROR: 127.0.0.1:$STATS_PORT already in use by something else. Aborting, nothing changed."
  exit 1
fi
echo "OK: ports free"

echo "== 4/6 write free300 config + unit =="
PASS=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
SECRET=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
mkdir -p /etc/hysteria "$STATE_DIR"
cat > "$FREE_CFG" <<EOF
listen: :$FREE_PORT

tls:
  cert: $CERT
  key: $KEY

trafficStats:
  listen: 127.0.0.1:$STATS_PORT
  secret: $SECRET

auth:
  type: password
  password: $PASS

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
chmod 600 "$FREE_CFG"
cat > "$SHARED_CONF" <<EOF
SECRET=$SECRET
LIMIT_GB=$LIMIT_GB
API=http://127.0.0.1:$STATS_PORT/traffic
EOF
chmod 600 "$SHARED_CONF"

cat > /etc/systemd/system/$UNIT.service <<EOF
[Unit]
Description=Hysteria2 FREE 300GB (promo)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config $FREE_CFG
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
# after a cert renewal the free instance must restart too, or it keeps serving the old cert
if [ -f /etc/cron.d/hysteria-cert-renew ] && ! grep -q $UNIT /etc/cron.d/hysteria-cert-renew; then
  sed -i "s/systemctl restart hysteria/systemctl restart hysteria $UNIT/" /etc/cron.d/hysteria-cert-renew || true
fi
systemctl daemon-reload
systemctl enable $UNIT >/dev/null 2>&1
systemctl restart $UNIT
sleep 3
systemctl is-active --quiet $UNIT || { echo "ERROR: $UNIT did not start."; journalctl -u $UNIT --no-pager -n 20; exit 1; }
ufw allow ${FREE_PORT}/udp >/dev/null 2>&1 || true
echo "OK: $UNIT running on UDP $FREE_PORT"

echo "== 5/6 quota guard (cron, every 5 min) =="
cat > /usr/local/bin/gs-hy2free-guard.sh <<'GUARD'
#!/bin/bash
# gs-hy2free-guard — meter HY2-FREE-300GB via the hysteria Traffic Stats API.
# Accumulates up+down of ALL users on the dedicated free instance (its total
# traffic) into a persistent counter; at >= LIMIT_GB the instance is stopped.
# ~5 min of traffic around a service restart may go uncounted (user's favour),
# same behaviour as the TUIC/SS promo guards.
CONF=/etc/hysteria/free300.conf
[ -f "$CONF" ] && . "$CONF"
API=${API:-http://127.0.0.1:9999/traffic}
SECRET=${SECRET:-}
LIMIT_GB=${LIMIT_GB:-300}
STATE_DIR=/var/lib/gs-hy2free
TOTAL_FILE=$STATE_DIR/bytes
STATUS=/root/hy2-free-usage.txt
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
  systemctl stop gs-hy2free 2>/dev/null || true
  STATE="EXHAUSTED — service stopped at ${LIMIT_GB}GB. Re-run setup-hy2-free300.sh to renew."
else
  STATE="ACTIVE"
fi
{
  echo "HY2-FREE-300GB usage"
  echo "  Used : ${USED} GiB / ${LIMIT_GB} GiB"
  echo "  Left : ${LEFT} GiB"
  echo "  State: $STATE"
  echo "  Updated: $(date -u '+%F %T UTC')"
} > "$STATUS"
GUARD
chmod +x /usr/local/bin/gs-hy2free-guard.sh
cat > /etc/cron.d/gs-hy2free-guard <<'EOF'
*/5 * * * * root /usr/local/bin/gs-hy2free-guard.sh >/dev/null 2>&1
EOF
# fresh counter for the new key, then one guard pass to seed the status file
echo 0 > "$STATE_DIR/bytes"
/usr/local/bin/gs-hy2free-guard.sh || true
echo "OK: guard installed, counter reset"

echo "== 6/6 stats API self-test + link =="
TEST=$(curl -s -m 10 -H "Authorization: $SECRET" "http://127.0.0.1:$STATS_PORT/traffic" || true)
case "$TEST" in
  *{*) echo "OK: traffic stats API answers ($TEST)" ;;
  *) echo "WARNING: stats API did not answer as expected (got: $TEST)"
     echo "         The key will work, but quota metering may not count — send this output for a fix." ;;
esac

LINK="hy2://${PASS}@${DOMAIN}:${FREE_PORT}?sni=${DOMAIN}#HY2-FREE-300GB"
echo "$LINK" > /root/my-hy2-free.txt
chmod 600 /root/my-hy2-free.txt
echo ""
echo "==========================================================="
echo "DONE: HY2-FREE-300GB is live"
echo ""
echo "Link (Aeriva / GOLDENSKY import):"
echo "$LINK"
echo ""
echo "  Port    : $FREE_PORT/udp   (open it in the LIGHTSAIL firewall!)"
echo "  Quota   : $LIMIT_GB GiB total, auto-stop by guard (cron 5 min)"
echo "  Usage   : cat /root/hy2-free-usage.txt"
echo "  Renew   : re-run this script (new password, counter reset)"
echo "  Main HY2: untouched (port 8443)"
echo "==========================================================="
