#!/bin/bash
# setup-wg500.sh — own-IP WireGuard TEST server on UDP 500 (for FirstByte JP, root)
# Adds a NEW wg500 interface only; touches no existing service.
# Re-run = brand-new keys (the old client link dies).
set -e
[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }

PORT=500
PUBIP=132.243.30.145

if ss -lun | grep -q ":$PORT "; then echo "UDP $PORT already in use - aborting"; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard-tools iptables >/dev/null

WANIF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$WANIF" ] || WANIF=eth0
echo "WAN interface: $WANIF"

mkdir -p /etc/wireguard
umask 077
S_PRIV=$(wg genkey); S_PUB=$(printf %s "$S_PRIV" | wg pubkey)
C_PRIV=$(wg genkey); C_PUB=$(printf %s "$C_PRIV" | wg pubkey)

cat > /etc/wireguard/wg500.conf <<EOF
[Interface]
PrivateKey = $S_PRIV
Address = 10.66.0.1/24
ListenPort = $PORT
PostUp = iptables -A FORWARD -i wg500 -j ACCEPT; iptables -t nat -A POSTROUTING -o $WANIF -j MASQUERADE
PostDown = iptables -D FORWARD -i wg500 -j ACCEPT; iptables -t nat -D POSTROUTING -o $WANIF -j MASQUERADE

[Peer]
PublicKey = $C_PUB
AllowedIPs = 10.66.0.2/32
EOF

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg500.conf
sysctl -p /etc/sysctl.d/99-wg500.conf >/dev/null

systemctl enable wg-quick@wg500 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg500
sleep 1
systemctl is-active wg-quick@wg500 || { journalctl -u wg-quick@wg500 -n 20 --no-pager; exit 1; }

urlenc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }
LINK="wireguard://$(urlenc "$C_PRIV")@$PUBIP:$PORT?address=10.66.0.2%2F32&presharedkey=&publickey=$(urlenc "$S_PUB")&mtu=1280#WG500-JP"

cat > /root/my-wg500.txt <<EOF
$LINK

[Interface]
PrivateKey = $C_PRIV
Address = 10.66.0.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $S_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = $PUBIP:$PORT
EOF
chmod 600 /root/my-wg500.txt

echo ""
echo "=== WG500 client link (copy this) ==="
echo "$LINK"
echo "=== also saved in /root/my-wg500.txt ==="
wg show wg500 | head -4
