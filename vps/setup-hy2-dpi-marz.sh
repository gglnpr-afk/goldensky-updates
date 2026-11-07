#!/bin/bash
# ============================================================
# setup-hy2-dpi-marz.sh — "strongest DPI" Hysteria2 pair for the
# Marzban box (83.147.235.168 / marz.gloriafreeproton.io).
# Marker: gs-hy2-dpi v1.1
#
# Installs TWO independent hysteria instances that COEXIST with
# Marzban (panel :8443/tcp, Plain VLESS :443/tcp, SS :1080):
# TCP and UDP are separate, so UDP 443 does not touch VLESS.
# v1.1: PLAIN moved 8443 -> 9443 — the panel's Caddy also binds
# UDP 8443 (HTTP/3 for the panel site), found on the first
# on-box run 2026-11-07 (kit aborted safely, nothing changed).
#
#   1) gs-hy2-strong  UDP 443   + Salamander obfs + port hopping
#      (iptables REDIRECT UDP 20000-30000 -> 443)
#      -> the toughest link: QUIC signature is scrambled to
#         random-looking data, masquerade answers probes.
#      -> Apps: Aeriva (build 112+ finalmask supports obfs+hopping)
#         and v2rayNG / sing-box clients.
#      -> NOT for the GOLDENSKY app: its parseHy2 ignores obfs/ports
#         entirely (source-verified 2026-11-07), so it would try to
#         connect WITHOUT the obfs mask and the server rejects it.
#
#   2) gs-hy2-plain   UDP 9443  plain HY2 (no obfs, no hopping)
#      -> GOLDENSKY-compatible link (same QUIC + masquerade +
#         real cert; just no salamander scramble).
#      -> Apps: GOLDENSKY, Aeriva, v2rayNG.
#
# TLS: a real Let's Encrypt cert is MANDATORY for GOLDENSKY/Aeriva
# (insecure=1 is ignored by their Xray core). This kit REUSES the
# cert Caddy already issued for the panel domain (found in the
# gs-caddy Docker volume or other standard Caddy/letsencrypt
# locations) — no new ACME round, no TCP 80 fight with Caddy.
# If no valid cert for the domain is found, the kit ABORTS and
# changes nothing on the proxy side.
# NOTE: the cert is COPIED at install time. Caddy renews its own
# copy (~every 60 days); if HY2 starts failing TLS months later,
# simply re-run this kit to pick up the renewed cert (re-running
# also rotates both passwords — old links stop working).
#
# Usage (single command, on the Marzban box):
#   curl -sL <link> -o hy2dpi.sh && sudo bash hy2dpi.sh
#   (domain is fixed to marz.gloriafreeproton.io; an optional
#    first argument overrides it)
#
# Remove:  systemctl disable --now gs-hy2-strong gs-hy2-plain
#          /usr/local/bin/gs-hy2-hop.sh del
#          rm -rf /etc/hysteria-dpi /root/my-hy2-dpi.txt
# ============================================================
set -e

DOMAIN="${1:-marz.gloriafreeproton.io}"
STRONG_PORT="${STRONG_PORT:-443}"
PLAIN_PORT="${PLAIN_PORT:-9443}"
HOP_LO=20000
HOP_HI=30000
DIR=/etc/hysteria-dpi
UNIT_S=gs-hy2-strong
UNIT_P=gs-hy2-plain
HYST_DL=https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
HYST_SHA=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691

echo "=== HY2 DPI-STRONG pair for Marzban box (domain: $DOMAIN) ==="
[ "$(id -u)" = "0" ] || { echo "Run as root:  sudo bash setup-hy2-dpi-marz.sh"; exit 1; }

# ---------- prerequisites (apt / dnf / yum aware — AlmaLinux has no apt) ----------
if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
else PKG=""; fi
pkg_install() {
  if [ "$PKG" = "apt" ]; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif [ "$PKG" = "dnf" ]; then dnf install -y "$@"
  elif [ "$PKG" = "yum" ]; then yum install -y "$@"
  else echo "!! No supported package manager; install manually: $*"; return 1; fi
}
NEED=""
command -v python3 >/dev/null 2>&1 || NEED="$NEED python3"
command -v curl    >/dev/null 2>&1 || NEED="$NEED curl"
command -v openssl >/dev/null 2>&1 || NEED="$NEED openssl"
if [ "$PKG" = "apt" ]; then
  command -v ss >/dev/null 2>&1 || NEED="$NEED iproute2"
else
  command -v ss >/dev/null 2>&1 || NEED="$NEED iproute"
fi
if [ -n "$NEED" ]; then
  echo "-- installing prerequisites:$NEED"
  pkg_install $NEED >/dev/null 2>&1 || pkg_install $NEED
fi
command -v python3 >/dev/null 2>&1 || { echo "!! python3 missing. Aborting."; exit 1; }

# ---------- public IP + domain check ----------
PUB_IP=$(curl -s -m 10 https://api.ipify.org || curl -s -m 10 https://ifconfig.me || curl -s -m 10 https://icanhazip.com || true)
PUB_IP=$(printf '%s' "$PUB_IP" | tr -dc '0-9.')
[ -n "$PUB_IP" ] || { echo "!! Could not detect this server's public IP. Aborting."; exit 1; }
echo "-- public IP: $PUB_IP"
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
  NOMATCH:*) echo "!! $DOMAIN resolves to ${HIT#NOMATCH:} — not this server ($PUB_IP). Aborting."
             exit 1 ;;
  *) echo "!! DNS check failed ($HIT) — continuing; the cert check below is the real gate." ;;
esac

# ---------- UDP ports must be free (our own old instances stop first) ----------
systemctl stop $UNIT_S $UNIT_P 2>/dev/null || true
sleep 1
for p in $STRONG_PORT $PLAIN_PORT; do
  if ss -lun | grep -q ":${p}[[:space:]]"; then
    echo "!! UDP $p is already in use by something else. Aborting (nothing changed):"
    ss -lunp | grep ":${p}[[:space:]]" || true
    echo "   (If a TUIC/other HY2 already owns UDP $p, do NOT force it — tell me and we pick another port.)"
    exit 1
  fi
done
echo "-- UDP $STRONG_PORT + $PLAIN_PORT free (Marzban TCP services untouched)"

# ---------- find the panel's real Let's Encrypt cert for $DOMAIN ----------
echo "-- looking for an existing Let's Encrypt cert for $DOMAIN..."
CERT_SRC=""; KEY_SRC=""
# Caddy Docker volume layout + host Caddy layouts + certbot layout
for d in $(find /var/lib/docker/volumes -type d -name "$DOMAIN" 2>/dev/null) \
         $(find /root /var/lib/caddy /home -maxdepth 8 -type d -name "$DOMAIN" 2>/dev/null); do
  if [ -f "$d/$DOMAIN.crt" ] && [ -f "$d/$DOMAIN.key" ]; then
    CERT_SRC="$d/$DOMAIN.crt"; KEY_SRC="$d/$DOMAIN.key"; break
  fi
done
if [ -z "$CERT_SRC" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
  CERT_SRC="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY_SRC="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi
if [ -z "$CERT_SRC" ]; then
  echo "!! No cert files for $DOMAIN found (checked the gs-caddy Docker volume,"
  echo "   host Caddy storage, and /etc/letsencrypt). The panel HTTPS must be"
  echo "   working first — check:  docker ps | grep caddy   and"
  echo "   curl -s -o /dev/null -w '%{http_code}\\n' https://$DOMAIN:8443/dashboard/"
  echo "   Aborting — nothing was changed."
  exit 1
fi
# Validate: cert covers the domain and is not expired / near expiry.
if ! openssl x509 -in "$CERT_SRC" -noout -text 2>/dev/null | grep -q "$DOMAIN"; then
  echo "!! Found cert ($CERT_SRC) does not cover $DOMAIN. Aborting."
  exit 1
fi
END_EPOCH=$(python3 - "$CERT_SRC" <<'PYEOF'
import subprocess, sys, datetime
out = subprocess.check_output(["openssl", "x509", "-in", sys.argv[1], "-noout", "-enddate"]).decode()
val = out.strip().split("=", 1)[1]
dt = datetime.datetime.strptime(val, "%b %d %H:%M:%S %Y %Z")
print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))
PYEOF
)
NOW_EPOCH=$(date +%s)
if [ "$END_EPOCH" -le $((NOW_EPOCH + 86400)) ]; then
  echo "!! Cert for $DOMAIN expires within 24h (or already expired). Let Caddy renew it first, then re-run. Aborting."
  exit 1
fi
echo "   OK: cert $CERT_SRC (valid, covers $DOMAIN)"

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

# ---------- passwords + cert copy ----------
umask 077
mkdir -p "$DIR"
PASS_STRONG=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
OBFS_PASS=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
PASS_PLAIN=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
cp "$CERT_SRC" "$DIR/cert.pem"
cp "$KEY_SRC" "$DIR/key.pem"
chmod 600 "$DIR/key.pem" "$DIR/cert.pem"

# ---------- configs ----------
{
  echo "listen: :$STRONG_PORT"
  echo ""
  echo "tls:"
  echo "  cert: $DIR/cert.pem"
  echo "  key: $DIR/key.pem"
  echo ""
  echo "obfs:"
  echo "  type: salamander"
  echo "  salamander:"
  echo "    password: $OBFS_PASS"
  echo ""
  echo "auth:"
  echo "  type: password"
  echo "  password: $PASS_STRONG"
  echo ""
  echo "masquerade:"
  echo "  type: proxy"
  echo "  proxy:"
  echo "    url: https://www.bing.com"
  echo "    rewriteHost: true"
} > "$DIR/strong.yaml"
{
  echo "listen: :$PLAIN_PORT"
  echo ""
  echo "tls:"
  echo "  cert: $DIR/cert.pem"
  echo "  key: $DIR/key.pem"
  echo ""
  echo "auth:"
  echo "  type: password"
  echo "  password: $PASS_PLAIN"
  echo ""
  echo "masquerade:"
  echo "  type: proxy"
  echo "  proxy:"
  echo "    url: https://www.bing.com"
  echo "    rewriteHost: true"
} > "$DIR/plain.yaml"
chmod 600 "$DIR/strong.yaml" "$DIR/plain.yaml"

# ---------- port-hopping helper (strong instance only) ----------
cat > /usr/local/bin/gs-hy2-hop.sh <<HOP
#!/bin/bash
# gs-hy2-dpi hop helper: REDIRECT UDP $HOP_LO:$HOP_HI -> $STRONG_PORT
IPT=\$(command -v iptables || echo /usr/sbin/iptables)
[ -x "\$IPT" ] || exit 0
case "\$1" in
  add) \$IPT -t nat -C PREROUTING -p udp --dport $HOP_LO:$HOP_HI -j REDIRECT --to-ports $STRONG_PORT 2>/dev/null \\
         || \$IPT -t nat -A PREROUTING -p udp --dport $HOP_LO:$HOP_HI -j REDIRECT --to-ports $STRONG_PORT 2>/dev/null || true ;;
  del) \$IPT -t nat -D PREROUTING -p udp --dport $HOP_LO:$HOP_HI -j REDIRECT --to-ports $STRONG_PORT 2>/dev/null || true ;;
esac
exit 0
HOP
chmod +x /usr/local/bin/gs-hy2-hop.sh

# ---------- systemd units ----------
cat > /etc/systemd/system/$UNIT_S.service <<EOF
[Unit]
Description=Hysteria2 DPI-STRONG (obfs + hopping, UDP $STRONG_PORT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/gs-hy2-hop.sh add
ExecStart=/usr/local/bin/hysteria server --config $DIR/strong.yaml
ExecStopPost=/usr/local/bin/gs-hy2-hop.sh del
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/$UNIT_P.service <<EOF
[Unit]
Description=Hysteria2 DPI-PLAIN for GOLDENSKY (UDP $PLAIN_PORT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config $DIR/plain.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable $UNIT_S $UNIT_P >/dev/null 2>&1 || true
# NOTE: enable --now does NOT restart an already-running unit — restart explicitly.
systemctl restart $UNIT_S $UNIT_P

echo "-- waiting for both servers to come up..."
UP=0
for i in $(seq 1 30); do
  sleep 2
  if systemctl is-active --quiet $UNIT_S && systemctl is-active --quiet $UNIT_P \
     && ss -lun | grep -q ":${STRONG_PORT}[[:space:]]" \
     && ss -lun | grep -q ":${PLAIN_PORT}[[:space:]]"; then UP=1; break; fi
done
if [ "$UP" != "1" ]; then
  echo "!! One of the units did not come up. Last log lines:"
  journalctl -u $UNIT_S --no-pager -n 15 || true
  journalctl -u $UNIT_P --no-pager -n 15 || true
  exit 1
fi
echo "OK: $UNIT_S on UDP $STRONG_PORT, $UNIT_P on UDP $PLAIN_PORT"
if command -v iptables >/dev/null 2>&1 && iptables -t nat -C PREROUTING -p udp --dport $HOP_LO:$HOP_HI -j REDIRECT --to-ports $STRONG_PORT 2>/dev/null; then
  echo "OK: hop REDIRECT UDP $HOP_LO-$HOP_HI -> $STRONG_PORT active"
else
  echo "NOTE: hop REDIRECT not confirmed (iptables missing?) — the STRONG link still works on UDP $STRONG_PORT itself."
fi

# ---------- firewall (only the active one is touched) ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow ${STRONG_PORT}/udp >/dev/null 2>&1 || true
  ufw allow ${PLAIN_PORT}/udp >/dev/null 2>&1 || true
  ufw allow ${HOP_LO}:${HOP_HI}/udp >/dev/null 2>&1 || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=${STRONG_PORT}/udp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=${PLAIN_PORT}/udp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=${HOP_LO}-${HOP_HI}/udp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

# ---------- links ----------
LINK_STRONG="hy2://${PASS_STRONG}@${DOMAIN}:${STRONG_PORT}?security=tls&sni=${DOMAIN}&obfs=salamander&obfs-password=${OBFS_PASS}&ports=${HOP_LO}-${HOP_HI}&hop_interval=30#HY2-DPI-STRONG"
LINK_PLAIN="hy2://${PASS_PLAIN}@${DOMAIN}:${PLAIN_PORT}?security=tls&sni=${DOMAIN}#HY2-DPI-PLAIN"
{
  echo "# HY2 DPI pair — Marzban box $DOMAIN (re-run setup-hy2-dpi-marz.sh = rotate)"
  echo "# STRONG (Aeriva / v2rayNG only — GOLDENSKY app cannot use obfs):"
  echo "$LINK_STRONG"
  echo "# PLAIN (GOLDENSKY + Aeriva + v2rayNG):"
  echo "$LINK_PLAIN"
} > /root/my-hy2-dpi.txt
chmod 600 /root/my-hy2-dpi.txt

echo ""
echo "==========================================================="
echo "DONE: HY2 DPI pair is live on $DOMAIN"
echo ""
echo "1) STRONG link — Aeriva / v2rayNG ONLY (obfs + hopping, UDP $STRONG_PORT):"
echo "$LINK_STRONG"
echo ""
echo "2) PLAIN link — GOLDENSKY app + Aeriva + v2rayNG (UDP $PLAIN_PORT):"
echo "$LINK_PLAIN"
echo ""
echo "  Saved   : /root/my-hy2-dpi.txt"
echo "  Test    : import -> connect -> My IP must show $PUB_IP"
echo "  Provider: if the VPS has a provider firewall panel, also open"
echo "            UDP $STRONG_PORT, UDP $PLAIN_PORT, UDP $HOP_LO-$HOP_HI there."
echo "  Renew   : re-run this script (new passwords; picks up renewed cert)"
echo "==========================================================="
