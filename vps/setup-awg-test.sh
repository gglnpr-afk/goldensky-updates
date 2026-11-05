#!/bin/bash
# setup-awg-test.sh — AmneziaWG TEST server on the JP box (UDP 51821).
#
# AmneziaWG = WireGuard + fingerprint obfuscation (junk packets before the
# handshake, padded handshake packets, randomised magic headers). This kit
# installs a userspace amneziawg-go daemon (official source v3.1.20260828,
# classic 1.x/2.0 parameter set for widest client compatibility), generates
# fresh keys + fresh random obfuscation parameters, and prints one client
# .conf for the AmneziaVPN app. Test question: does the carrier DPI that
# kills plain WireGuard (rx: 0 B on every port, incl. UDP 443) let the
# obfuscated handshake through?
#
# Coexists with everything on the box: own interface awg0, own systemd unit
# gs-awg-test, own port UDP 51821, own subnet 10.66.68.0/24. Aborts before
# changing anything if UDP 51821 is held by another process.
# Re-running ROTATES keys + parameters (old unit stopped first).
# Remove: systemctl disable --now gs-awg-test; rm /usr/local/bin/amneziawg-go
#         /usr/local/bin/awg /etc/amnezia/amneziawg/awg0.conf
set -e

PORT=51821
IFACE=awg0
SRV_IP=10.66.68.1
CLI_IP=10.66.68.2
SUBNET=10.66.68.0/24
PUB_IP=132.243.30.145
CFGDIR=/etc/amnezia/amneziawg
GO_SHA=794e89b841d093d9e8d29f1ef91088fad8bf7260224bfe0ae5ed32dcbebb1bff
GO_URL=https://muse.ai/files/1305209252684995/2099962253968278/tdrxsespmymej493pqm7n3id/amneziawg-go.bin
SRC_SHA=24c656cfb80ff6855702710eaf2e3729fa710bf6bfdbbbdfba01984ccd17de95
TOOLS_URL=https://github.com/amnezia-vpn/amneziawg-tools/releases/download/v3.1.20260812/ubuntu-22.04-amneziawg-tools.zip
TOOLS_SHA=919e9d0a367c7c72f9c16b7d0a9e4840b943628353b2210a33cb4b582785ba56

echo "=== AmneziaWG TEST server (UDP $PORT) ==="
[ "$(id -u)" = "0" ] || { echo "!! Run as root. Aborting."; exit 1; }

# rotation: stop our own previous instance first (frees the port)
systemctl stop gs-awg-test 2>/dev/null || true
sleep 1

if ss -lun | grep -q ":$PORT "; then
  echo "!! UDP $PORT is already in use. Aborting (nothing changed):"
  ss -lunp | grep ":$PORT " || true
  exit 1
fi
[ -c /dev/net/tun ] || { echo "!! /dev/net/tun missing — userspace daemon cannot run. Aborting."; exit 1; }

echo "-- egress interface:"
EGRESS=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+' | head -1)
echo "   $EGRESS"

# ---------- awg tool (official prebuilt, sha-pinned) ----------
if [ ! -x /usr/local/bin/awg ]; then
  echo "-- installing awg tool..."
  curl -fsSL --max-time 120 -o /tmp/awg-tools.zip "$TOOLS_URL"
  echo "$TOOLS_SHA  /tmp/awg-tools.zip" | sha256sum -c - >/dev/null
  python3 -c "import zipfile; zipfile.ZipFile('/tmp/awg-tools.zip').extractall('/tmp/awg-tools')"
  install -m 0755 /tmp/awg-tools/ubuntu-22.04-amneziawg-tools/awg /usr/local/bin/awg
  rm -rf /tmp/awg-tools /tmp/awg-tools.zip
fi
/usr/local/bin/awg --version >/dev/null 2>&1 || { echo "!! awg binary cannot run on this box (glibc?). Aborting."; exit 1; }
echo "   awg: $(/usr/local/bin/awg --version)"

# ---------- amneziawg-go daemon ----------
install_daemon_from_link() {
  curl -fsSL --max-time 180 -o /tmp/amneziawg-go "$GO_URL" || return 1
  echo "$GO_SHA  /tmp/amneziawg-go" | sha256sum -c - >/dev/null 2>&1 || return 1
  install -m 0755 /tmp/amneziawg-go /usr/local/bin/amneziawg-go
  rm -f /tmp/amneziawg-go
  return 0
}
build_daemon_from_source() {
  echo "-- prebuilt link unavailable — building amneziawg-go from source (2-5 min)..."
  mkdir -p /root/.awg-build && cd /root/.awg-build
  if [ ! -x /root/.awg-build/go/bin/go ]; then
    curl -fsSL --max-time 600 -o go.tgz https://dl.google.com/go/go1.25.5.linux-amd64.tar.gz
    tar xzf go.tgz
  fi
  curl -fsSL --max-time 120 -o src.tgz https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/refs/tags/v3.1.20260828
  echo "$SRC_SHA  src.tgz" | sha256sum -c - >/dev/null
  tar xzf src.tgz && cd amneziawg-go-3.1.20260828
  GOTOOLCHAIN=local CGO_ENABLED=0 /root/.awg-build/go/bin/go build -trimpath -o /usr/local/bin/amneziawg-go .
  cd /; rm -rf /root/.awg-build
}
if [ ! -x /usr/local/bin/amneziawg-go ]; then
  install_daemon_from_link || build_daemon_from_source
fi
[ -x /usr/local/bin/amneziawg-go ] || { echo "!! daemon install failed. Aborting."; exit 1; }
echo "   daemon installed"

# ---------- keys + obfuscation parameters ----------
mkdir -p "$CFGDIR"
SRV_PRIV=$(/usr/local/bin/awg genkey); SRV_PUB=$(echo "$SRV_PRIV" | /usr/local/bin/awg pubkey)
CLI_PRIV=$(/usr/local/bin/awg genkey); CLI_PUB=$(echo "$CLI_PRIV" | /usr/local/bin/awg pubkey)
rnd() { od -An -tu4 -N4 /dev/urandom | tr -d ' \n'; }
JC=$((4 + $(rnd) % 5))
JMIN=$((40 + $(rnd) % 50))
JMAX=$((JMIN + 60 + $(rnd) % 141))
S1=$((15 + $(rnd) % 136))
S2=$((15 + $(rnd) % 136)); while [ $((S1 + 56)) -eq $S2 ]; do S2=$((15 + $(rnd) % 136)); done
H1=0; H2=0; H3=0; H4=0
while [ $H1 -eq 0 ]; do H1=$((100000000 + $(rnd) % 3800000000)); done
while [ $H2 -eq 0 ] || [ $H2 -eq $H1 ]; do H2=$((100000000 + $(rnd) % 3800000000)); done
while [ $H3 -eq 0 ] || [ $H3 -eq $H1 ] || [ $H3 -eq $H2 ]; do H3=$((100000000 + $(rnd) % 3800000000)); done
while [ $H4 -eq 0 ] || [ $H4 -eq $H1 ] || [ $H4 -eq $H2 ] || [ $H4 -eq $H3 ]; do H4=$((100000000 + $(rnd) % 3800000000)); done
PARAMS="Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4"

# server config for `awg setconf` (keys/port/params/peers only)
cat > "$CFGDIR/$IFACE.conf" <<EOF
[Interface]
PrivateKey = $SRV_PRIV
ListenPort = $PORT
$PARAMS

[Peer]
PublicKey = $CLI_PUB
AllowedIPs = $CLI_IP/32
EOF
chmod 600 "$CFGDIR/$IFACE.conf"

# ---------- daemon under systemd ----------
cat > /etc/systemd/system/gs-awg-test.service <<'EOF'
[Unit]
Description=AmneziaWG TEST server (awg0, UDP 51821)
After=network.target

[Service]
ExecStart=/usr/local/bin/amneziawg-go -f awg0
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable gs-awg-test >/dev/null 2>&1 || true
systemctl restart gs-awg-test

for i in $(seq 1 20); do [ -S /var/run/amneziawg/$IFACE.sock ] && break; sleep 0.5; done
[ -S /var/run/amneziawg/$IFACE.sock ] || { echo "!! daemon did not come up:"; journalctl -u gs-awg-test -n 20 --no-pager; exit 1; }

/usr/local/bin/awg setconf $IFACE "$CFGDIR/$IFACE.conf"
ip address add $SRV_IP/24 dev $IFACE
ip link set $IFACE up

# ---------- routing / NAT ----------
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-test.conf
iptables -t nat -C POSTROUTING -s $SUBNET -o "$EGRESS" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s $SUBNET -o "$EGRESS" -j MASQUERADE

systemctl is-active gs-awg-test
/usr/local/bin/awg show $IFACE

# ---------- client output ----------
OUT=/root/my-awg-test.txt
{
  echo "AmneziaWG TEST — import the .conf below into the AmneziaVPN app"
  echo "Server: $PUB_IP:$PORT (JP box)  Interface: $IFACE"
  echo ""
  echo "----- CLIENT .conf -----"
  echo "[Interface]"
  echo "PrivateKey = $CLI_PRIV"
  echo "Address = $CLI_IP/32"
  echo "DNS = 1.1.1.1"
  echo "$PARAMS"
  echo ""
  echo "[Peer]"
  echo "PublicKey = $SRV_PUB"
  echo "Endpoint = $PUB_IP:$PORT"
  echo "AllowedIPs = 0.0.0.0/0"
  echo "PersistentKeepalive = 25"
} > "$OUT"
chmod 600 "$OUT"
echo ""
cat "$OUT"
