#!/bin/bash
# ============================================================
# setup-anytls-anyip.sh — portable AnyTLS server for ANY box/IP
#
# AnyTLS runs on sing-box. The generated links match GOLDENSKY
# 1.0.38's anytls:// parser exactly (password-only userinfo;
# sni / insecure params), lab-verified against the app sources.
#
# Two TLS modes:
#   DOMAIN mode  : real Let's Encrypt cert via sing-box's built-in
#                  ACME (tls.acme) -> no insecure flag in the link.
#                  The domain's A record MUST point to this server;
#                  ACME challenges need TCP 80 (HTTP) or this
#                  server's own port (TLS-ALPN) reachable — open
#                  them in the provider firewall.
#   IP mode ("-"): self-signed cert -> link has insecure=1.
#                  GOLDENSKY DOES accept this one: its AnyTLS runs
#                  on the libbox/sing-box core, which honours
#                  insecure=1 (lab-proven — the outbound carries
#                  tls.insecure=true). Unlike HY2, whose Xray core
#                  ignores insecure. Domain mode is still preferred
#                  (real cert, no insecure flag).
#
# Usage:
#   sudo bash setup-anytls-anyip.sh <DOMAIN|-> [QUOTA_GB]
#     sudo bash setup-anytls-anyip.sh tls.example.com        # unlimited
#     sudo bash setup-anytls-anyip.sh tls.example.com 300    # 300 GiB cap
#     sudo bash setup-anytls-anyip.sh -                      # bare IP mode
# Env: ANYTLS_PORT (default 443), ANYTLS_NAME (link name).
#
# Own unit gs-anytls, own config /etc/sing-box/config-anytls.json —
# coexists with other services (incl. a TUIC sing-box: untouched).
# Re-running = RENEW (new password; quota counter reset).
# Firewall: open TCP $ANYTLS_PORT in the provider panel if the box
# has one (e.g. Lightsail).
#
# Quota mode uses the SAME proven metering as the TUIC kit:
# sing-box's v2ray_api per-user stats + gs-stats-query + a delta
# guard (cron */5). Stock sing-box builds CANNOT do this (the stats
# service needs the with_v2ray_api build tag — a stock binary fails
# config check with "v2ray api is not included in this build"), so
# quota mode runs gs-anytls on the proven stats build, installed
# SIDE-BY-SIDE as /usr/local/bin/sing-box-gs. An existing sing-box
# (e.g. the TUIC server's) is never overwritten or restarted.
# ============================================================
set -e

DOMAIN="${1:-}"
QUOTA_GB="${2:-0}"
PORT="${ANYTLS_PORT:-443}"
STATS_ADDR=127.0.0.1:10088
STATS_PORT=10088
UNIT=gs-anytls
CFG=/etc/sing-box/config-anytls.json
SHARED_CONF=/etc/sing-box/anytls.conf
STATE_DIR=/var/lib/gs-anytls
CERT_DIR=/etc/sing-box/selfsigned-anytls
ACME_DIR=/etc/sing-box/acme-anytls
GS_BIN=/usr/local/bin/sing-box-gs
QUERY_BIN=/usr/local/bin/gs-stats-query
SB_VER=1.14.4
SB_URL=https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz
SB_SHA=699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968
GS_URL=https://github.com/gglnpr-afk/aeriva-updates/releases/download/tuic-kit-1/sing-box-quota.gz
GS_SHA=f44f422c25835385c8b2f423870e730bcc5c32aab9236aa02ea3517dd2009509
QUERY_URL=https://github.com/gglnpr-afk/aeriva-updates/releases/download/tuic-kit-1/gs-stats-query.gz
QUERY_SHA=e186ea38dfce1089cbf028f8924fa9d614f406c5457770a9f5cad4e840b81d4d

MODE=acme
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "-" ]; then MODE=selfsigned; fi
case "$QUOTA_GB" in *[!0-9]*|'') QUOTA_GB=0 ;; esac

echo "=== AnyTLS portable installer (mode: $MODE, port: $PORT, quota: ${QUOTA_GB}GB) ==="
[ "$(id -u)" = "0" ] || { echo "Run as root:  sudo bash setup-anytls-anyip.sh <DOMAIN|-> [QUOTA_GB]"; exit 1; }
NEED=""
for c in curl openssl python3 gzip tar ss; do
  command -v "$c" >/dev/null 2>&1 || NEED="$NEED $c"
done
if [ -n "$NEED" ]; then
  echo "-- installing missing tools:$NEED"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl openssl python3 gzip tar iproute2 >/dev/null
fi

# renew: stop our own previous instance first (frees the ports)
systemctl stop $UNIT 2>/dev/null || true
sleep 1
if ss -ltn | grep -q ":${PORT}[[:space:]]"; then
  echo "!! TCP $PORT already in use by something else. Aborting (nothing changed):"
  ss -ltnp | grep ":${PORT}[[:space:]]" || true
  echo "   Tip: pick another port, e.g.  ANYTLS_PORT=8443 sudo -E bash setup-anytls-anyip.sh ..."
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
    echo "!! WARNING: TCP 80 is already bound (see below) — the ACME HTTP challenge may fail;"
    echo "   the TLS-ALPN challenge runs on TCP $PORT itself and can still succeed."
    ss -ltnp | grep ":80[[:space:]]" || true
  fi
fi

# ---------- sing-box binary ----------
# Quota mode needs the v2ray_api stats build (see header): it lives
# side-by-side as $GS_BIN and only gs-anytls uses it. Non-quota mode
# uses any existing sing-box, or installs the pinned stock release.
if [ "$QUOTA_GB" -gt 0 ]; then
  BIN="$GS_BIN"
  if [ -x "$BIN" ]; then
    echo "-- stats sing-box already installed: $("$BIN" version 2>/dev/null | head -1)"
  else
    echo "-- installing stats-capable sing-box (side-by-side, for quota metering)..."
    curl -fsSL --max-time 300 -o /tmp/sing-box-gs.gz "$GS_URL"
    echo "$GS_SHA  /tmp/sing-box-gs.gz" | sha256sum -c - >/dev/null
    gzip -dc /tmp/sing-box-gs.gz > /tmp/sing-box-gs.bin
    install -m 0755 /tmp/sing-box-gs.bin "$BIN"
    rm -f /tmp/sing-box-gs.gz /tmp/sing-box-gs.bin
  fi
  if [ -x "$QUERY_BIN" ]; then
    echo "-- gs-stats-query already installed"
  else
    echo "-- installing gs-stats-query..."
    curl -fsSL --max-time 120 -o /tmp/gs-stats-query.gz "$QUERY_URL"
    echo "$QUERY_SHA  /tmp/gs-stats-query.gz" | sha256sum -c - >/dev/null
    gzip -dc /tmp/gs-stats-query.gz > /tmp/gs-stats-query.bin
    install -m 0755 /tmp/gs-stats-query.bin "$QUERY_BIN"
    rm -f /tmp/gs-stats-query.gz /tmp/gs-stats-query.bin
  fi
else
  BIN=""
  for c in /usr/local/bin/sing-box /usr/bin/sing-box; do
    if [ -x "$c" ]; then BIN="$c"; break; fi
  done
  if [ -z "$BIN" ]; then
    FOUND=$(command -v sing-box || true)
    [ -n "$FOUND" ] && BIN="$FOUND"
  fi
  if [ -n "$BIN" ]; then
    echo "-- sing-box already installed: $("$BIN" version 2>/dev/null | head -1) ($BIN)"
  else
    echo "-- installing sing-box v$SB_VER..."
    curl -fsSL --max-time 300 -o /tmp/sing-box.tar.gz "$SB_URL"
    echo "$SB_SHA  /tmp/sing-box.tar.gz" | sha256sum -c - >/dev/null
    mkdir -p /tmp/sing-box-x
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/sing-box-x
    install -m 0755 "/tmp/sing-box-x/sing-box-$SB_VER-linux-amd64/sing-box" /usr/local/bin/sing-box
    rm -rf /tmp/sing-box.tar.gz /tmp/sing-box-x
    BIN=/usr/local/bin/sing-box
  fi
fi
echo "   engine: $("$BIN" version 2>/dev/null | head -1) at $BIN"

# ---------- certificate (IP mode) ----------
mkdir -p /etc/sing-box "$STATE_DIR"
if [ "$MODE" = "selfsigned" ]; then
  mkdir -p "$CERT_DIR"
  if [ ! -f "$CERT_DIR/cert.pem" ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
      -days 3650 -nodes -subj "/CN=$PUB_IP" \
      -addext "subjectAltName=IP:$PUB_IP" 2>/dev/null
    chmod 600 "$CERT_DIR/key.pem"
  fi
fi

# ---------- config ----------
PASS=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
python3 - "$MODE" "$DOMAIN" "$PUB_IP" "$PORT" "$PASS" "$QUOTA_GB" "$CFG" "$STATS_ADDR" "$CERT_DIR" "$ACME_DIR" <<'PYEOF'
import json, sys
mode, domain, pub_ip, port, password, quota_gb, cfg_path, stats_addr, cert_dir, acme_dir = sys.argv[1:11]
# Documented sing-box default padding scheme (AnyTLS inbound docs).
padding = ["stop=8", "0=30-30", "1=100-400",
           "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
           "3=9-9,500-1000", "4=500-1000", "5=500-1000",
           "6=500-1000", "7=500-1000"]
if mode == "acme":
    tls = {"enabled": True, "server_name": domain,
           "acme": {"domain": [domain], "data_directory": acme_dir,
                    "email": "admin@" + domain}}
else:
    tls = {"enabled": True,
           "certificate_path": cert_dir + "/cert.pem",
           "key_path": cert_dir + "/key.pem"}
cfg = {
    "log": {"level": "info", "timestamp": True},
    "inbounds": [{
        "type": "anytls", "tag": "anytls-in",
        "listen": "::", "listen_port": int(port),
        "users": [{"name": "main", "password": password}],
        "padding_scheme": padding,
        "tls": tls,
    }],
    "outbounds": [{"type": "direct", "tag": "direct"}],
}
if int(quota_gb) > 0:
    cfg["experimental"] = {"v2ray_api": {
        "listen": stats_addr,
        "stats": {"enabled": True, "inbounds": ["anytls-in"],
                  "users": ["main"]}}}
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("config written:", cfg_path)
PYEOF
chmod 600 "$CFG"
if ! "$BIN" check -c "$CFG"; then
  echo "!! sing-box rejected the generated config (see above). Aborting — nothing was started."
  exit 1
fi
echo "-- config check OK"

cat > /etc/systemd/system/$UNIT.service <<EOF
[Unit]
Description=AnyTLS (portable, $MODE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CFG
Restart=always
RestartSec=5
LimitNOFILE=1048576

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
  if systemctl is-active --quiet $UNIT && ss -ltn | grep -q ":${PORT}[[:space:]]"; then UP=1; break; fi
done
if [ "$UP" != "1" ]; then
  echo "!! $UNIT did not come up. Last log lines:"
  journalctl -u $UNIT --no-pager -n 25
  [ "$MODE" = "acme" ] && echo "   ACME hints: $DOMAIN must point to $PUB_IP; TCP 80 (HTTP challenge) or TCP $PORT (TLS-ALPN) must be reachable from the internet — check the provider firewall."
  exit 1
fi
ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
[ "$MODE" = "acme" ] && ufw allow 80/tcp >/dev/null 2>&1 || true
echo "OK: $UNIT running on TCP $PORT"

# ---------- optional quota guard ----------
if [ "$QUOTA_GB" -gt 0 ]; then
  echo "-- installing ${QUOTA_GB}GB quota guard..."
  cat > "$SHARED_CONF" <<EOF
STATS_ADDR=$STATS_ADDR
LIMIT_GB=$QUOTA_GB
UNIT=$UNIT
STATS_USER=main
EOF
  chmod 600 "$SHARED_CONF"
  cat > /usr/local/bin/gs-anytls-guard.sh <<'GUARD'
#!/bin/bash
# gs-anytls-guard — meter the portable AnyTLS server via sing-box's
# v2ray_api per-user stats (user>>><name>>>>traffic>>>uplink/downlink),
# queried with gs-stats-query (same proven mechanism as gs-tuic-guard).
# Deltas accumulate into a persistent counter; at >= LIMIT_GB the
# instance is stopped. Counters reset whenever the service restarts:
# delta = cur-last when cur >= last, else cur; a counter seen for the
# first time only sets the baseline — always in the customer's favour.
CONF=${GS_ANYTLS_CONF:-/etc/sing-box/anytls.conf}
[ -f "$CONF" ] && . "$CONF"
STATS_ADDR=${STATS_ADDR:-127.0.0.1:10088}
LIMIT_GB=${LIMIT_GB:-300}
UNIT=${UNIT:-gs-anytls}
STATS_USER=${STATS_USER:-main}
QUERY=${QUERY:-/usr/local/bin/gs-stats-query}
STATE_DIR=${STATE_DIR:-/var/lib/gs-anytls}
STATUS=${STATUS:-/root/anytls-usage.txt}
mkdir -p "$STATE_DIR"
TOTAL_FILE=$STATE_DIR/bytes
LAST_FILE=$STATE_DIR/last.tsv
[ -f "$TOTAL_FILE" ] || echo 0 > "$TOTAL_FILE"
TOTAL=$(tr -dc '0-9' < "$TOTAL_FILE"); [ -n "$TOTAL" ] || TOTAL=0

RAW_FILE=$(mktemp)
trap 'rm -f "$RAW_FILE"' EXIT
"$QUERY" -addr "$STATS_ADDR" > "$RAW_FILE" 2>/dev/null || : > "$RAW_FILE"
DELTA=$(python3 - "$LAST_FILE" "$STATS_USER" "$RAW_FILE" <<'PYEOF'
import sys

last_path, user, raw_path = sys.argv[1], sys.argv[2], sys.argv[3]
last = {}
try:
    with open(last_path) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) == 2:
                try:
                    last[p[0]] = int(p[1])
                except ValueError:
                    pass
except FileNotFoundError:
    pass

delta = 0
seen = dict(last)
with open(raw_path) as raw:
    lines = raw.readlines()
for line in lines:
    parts = line.split()
    if len(parts) != 2:
        continue
    name = parts[0]
    fields = name.split(">>>")
    if len(fields) != 4 or fields[0] != "user" or fields[1] != user or fields[2] != "traffic":
        continue
    try:
        val = int(parts[1])
    except ValueError:
        continue
    prev = last.get(name)
    if prev is None:
        d = 0  # first sighting: baseline only
    elif val >= prev:
        d = val - prev
    else:
        d = val  # counter reset by a service restart
    delta += d
    seen[name] = val

with open(last_path, "w") as f:
    for k in sorted(seen):
        f.write("%s\t%d\n" % (k, seen[k]))
print(delta)
PYEOF
)
if [ -n "$DELTA" ] && [ "$DELTA" -ge 0 ] 2>/dev/null; then
  TOTAL=$((TOTAL + DELTA))
  echo "$TOTAL" > "$TOTAL_FILE.tmp" && mv "$TOTAL_FILE.tmp" "$TOTAL_FILE"
fi

LIMIT=$((LIMIT_GB * 1024 * 1024 * 1024))
USED=$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t/1073741824}')
LEFT=$(awk -v t="$TOTAL" -v l="$LIMIT" 'BEGIN{d=l-t; if(d<0)d=0; printf "%.2f", d/1073741824}')
if [ "$TOTAL" -ge "$LIMIT" ]; then
  systemctl stop "$UNIT" 2>/dev/null || true
  STATE="EXHAUSTED — service stopped at ${LIMIT_GB}GB. Re-run setup-anytls-anyip.sh to renew."
else
  STATE="ACTIVE"
fi
{
  echo "AnyTLS (portable) usage"
  echo "  Used : ${USED} GiB / ${LIMIT_GB} GiB"
  echo "  Left : ${LEFT} GiB"
  echo "  State: $STATE"
  echo "  Updated: $(date -u '+%F %T UTC')"
} > "$STATUS"
GUARD
  chmod +x /usr/local/bin/gs-anytls-guard.sh
  cat > /etc/cron.d/gs-anytls-guard <<'EOF'
*/5 * * * * root /usr/local/bin/gs-anytls-guard.sh >/dev/null 2>&1
EOF
  echo 0 > "$STATE_DIR/bytes"
  rm -f "$STATE_DIR/last.tsv"
  /usr/local/bin/gs-anytls-guard.sh || true
  echo "-- checking stats API..."
  OK=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if "$QUERY_BIN" -addr "$STATS_ADDR" >/dev/null 2>&1; then OK=1; break; fi
    sleep 1
  done
  if [ "$OK" = "1" ]; then
    echo "OK: stats API answers ($STATS_ADDR) — quota metering is live"
  else
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! WARNING: stats API did not answer — quota metering is NOT"
    echo "!! counting yet. The guard IS installed and keeps retrying."
    echo "!! Inspect: journalctl -u $UNIT -n 30"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  fi
else
  # non-quota (re)run: drop any guard left by a previous quota install
  rm -f /etc/cron.d/gs-anytls-guard "$SHARED_CONF"
fi

# ---------- link ----------
if [ -n "${ANYTLS_NAME:-}" ]; then NAME="$ANYTLS_NAME";
elif [ "$QUOTA_GB" -gt 0 ]; then NAME="AnyTLS-FREE-${QUOTA_GB}GB";
else NAME="AnyTLS"; fi
if [ "$MODE" = "acme" ]; then
  LINK="anytls://${PASS}@${DOMAIN}:${PORT}?sni=${DOMAIN}#${NAME}"
else
  LINK="anytls://${PASS}@${PUB_IP}:${PORT}?insecure=1&sni=${PUB_IP}#${NAME}"
fi
echo "$LINK" > /root/my-anytls.txt
chmod 600 /root/my-anytls.txt
echo ""
echo "==========================================================="
echo "DONE: AnyTLS is live ($MODE mode)"
echo ""
echo "Link:"
echo "$LINK"
echo ""
echo "  Port    : $PORT/tcp — open it in the provider firewall if the box has one (Lightsail!)"
[ "$MODE" = "acme" ] && echo "  ACME    : keep TCP 80 open too if you can (HTTP challenge); TLS-ALPN runs on TCP $PORT itself"
[ "$QUOTA_GB" -gt 0 ] && echo "  Quota   : $QUOTA_GB GiB total, auto-stop by guard (cron 5 min); usage: cat /root/anytls-usage.txt"
echo "  Renew   : re-run this script (new password; quota counter reset)"
if [ "$MODE" = "selfsigned" ]; then
  echo ""
  echo "  IP MODE: self-signed cert (insecure=1). GOLDENSKY accepts it —"
  echo "  its AnyTLS core (libbox/sing-box) honours insecure=1. Strict"
  echo "  clients may still refuse it; DOMAIN mode gives a real cert:"
  echo "     sudo bash setup-anytls-anyip.sh <your-domain>"
fi
echo "==========================================================="
