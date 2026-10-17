#!/bin/bash
# ============================================================
# Add an OpenVPN client: builds a ready-to-import .ovpn file.
# Usage:  sudo bash add-ovpn-client.sh <name> [host]
#   <name>  client name, e.g. ko-aung   (tracked in /root/ovpn-users.txt)
#   [host]  server address written into the file
#           (default: this server's public IP — pass your domain
#            instead, e.g. donatekey.realty, so it survives IP changes)
# Example: sudo bash add-ovpn-client.sh ko-aung donatekey.realty
# The file lands at /root/ovpn-clients/<name>.ovpn — copy it to the
# phone (Termius: cat the file, or SFTP download) and import it into
# the "OpenVPN Connect" / "OpenVPN for Android" app.
# ============================================================
set -e
if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash add-ovpn-client.sh <name> [host]"
  exit 1
fi
NAME=${1:-}
[ -z "$NAME" ] && { echo "Usage: sudo bash add-ovpn-client.sh <name> [host]"; exit 1; }
[ -d /etc/openvpn/easy-rsa/pki ] || { echo "Run setup-openvpn.sh first."; exit 1; }
HOST=${2:-$(curl -s --max-time 8 https://api.ipify.org)}
[ -z "$HOST" ] && HOST=$(hostname -I | awk '{print $1}')

cd /etc/openvpn/easy-rsa
if [ -f "pki/issued/${NAME}.crt" ]; then
  echo "Client '$NAME' already exists — reusing its cert."
else
  echo "== cert for $NAME =="
  ./easyrsa --batch build-client-full "$NAME" nopass > /dev/null 2>&1
  echo "$NAME  $(date -u +%F)" >> /root/ovpn-users.txt
fi

mkdir -p /root/ovpn-clients
OUT=/root/ovpn-clients/${NAME}.ovpn
{
echo "client"
echo "dev tun"
echo "proto udp"
echo "remote $HOST 1194"
echo "resolv-retry infinite"
echo "nobind"
echo "persist-key"
echo "persist-tun"
echo "remote-cert-tls server"
echo "cipher AES-256-GCM"
echo "auth SHA256"
echo "verb 3"
echo "<ca>"
cat /etc/openvpn/server/ca.crt
echo "</ca>"
echo "<cert>"
cat "pki/issued/${NAME}.crt"
echo "</cert>"
echo "<key>"
cat "pki/private/${NAME}.key"
echo "</key>"
echo "<tls-crypt>"
cat /etc/openvpn/server/ta.key
echo "</tls-crypt>"
} > "$OUT"
chmod 600 "$OUT"
echo ""
echo "Created: $OUT   (host: $HOST)"
echo "Copy it to the phone and import into the OpenVPN app."
