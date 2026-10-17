#!/bin/bash
# ============================================================
# GOLDENSKY VPS — one-shot OpenVPN server setup (UDP 1194).
# Run ONCE per VPS:  curl -sSL <tinyurl> | sudo bash
# NOTE: also open UDP 1194 in your provider's firewall panel
# (e.g. Lightsail -> Networking -> Add rule -> Custom / UDP 1194).
# Then add clients:  sudo bash add-ovpn-client.sh <name> [host]
# ============================================================
set -e
if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  curl -sSL <url> | sudo bash"
  exit 1
fi

OVPN_SUBNET="10.9.0.0/24"

echo "== 1/5 packages =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openvpn easy-rsa iptables-persistent > /dev/null

echo "== 2/5 PKI (CA + server cert) =="
rm -rf /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/easy-rsa /etc/openvpn/server
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa
./easyrsa init-pki > /dev/null 2>&1
./easyrsa --batch build-ca nopass > /dev/null 2>&1
./easyrsa --batch build-server-full server nopass > /dev/null 2>&1
openvpn --genkey secret /etc/openvpn/server/ta.key
cp pki/ca.crt pki/issued/server.crt pki/private/server.key /etc/openvpn/server/
chmod 600 /etc/openvpn/server/server.key /etc/openvpn/server/ta.key

echo "== 3/5 server.conf =="
cat > /etc/openvpn/server/server.conf <<'EOF'
port 1194
proto udp
dev tun
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh none
topology subnet
server 10.9.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
tls-crypt /etc/openvpn/server/ta.key
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

echo "== 4/5 forwarding + NAT + firewall =="
sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null \
  || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
[ -z "$IFACE" ] && IFACE="eth0"
ufw allow 1194/udp > /dev/null 2>&1 || true
# ufw's before.rules NAT (only if ufw is installed)
if [ -f /etc/ufw/before.rules ] && ! grep -q "10.9.0.0/24" /etc/ufw/before.rules; then
  printf '*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.9.0.0/24 -o %s -j MASQUERADE\nCOMMIT\n' \
    "$IFACE" > /tmp/ovpn-nat.rules
  cat /etc/ufw/before.rules >> /tmp/ovpn-nat.rules
  mv /tmp/ovpn-nat.rules /etc/ufw/before.rules
fi
# direct iptables as well (covers ufw-inactive boxes; -I puts ours first)
iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j MASQUERADE
iptables -C FORWARD -s 10.9.0.0/24 -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD -s 10.9.0.0/24 -j ACCEPT
iptables -C FORWARD -d 10.9.0.0/24 -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD -d 10.9.0.0/24 -j ACCEPT
netfilter-persistent save > /dev/null 2>&1 || true

echo "== 5/5 start =="
systemctl enable --now openvpn-server@server > /dev/null 2>&1
sleep 2
if systemctl is-active --quiet openvpn-server@server; then
  echo "OpenVPN server: RUNNING (udp 1194, subnet 10.9.0.0/24)"
else
  echo "FAILED to start - check: journalctl -u openvpn-server@server -n 30"
  exit 1
fi
echo ""
echo "NEXT STEPS:"
echo " 1) Open UDP 1194 in your provider firewall (Lightsail -> Networking)."
echo " 2) Add a client:  sudo bash add-ovpn-client.sh <name> [host]"
echo "    e.g.  sudo bash add-ovpn-client.sh ko-aung donatekey.realty"
