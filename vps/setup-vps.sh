#!/bin/bash
# ============================================================
# GOLDENSKY VPS one-shot setup
# Installs Xray + configures VLESS + REALITY on port 443.
# - Ubuntu 22.04 (or 20.04/24.04), run as root
# - No domain name needed (REALITY camouflages as microsoft.com)
# Usage:  bash setup-vps.sh
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash setup-vps.sh"
  exit 1
fi

echo "== 1/5 packages =="
apt-get update -qq
apt-get install -y -qq curl openssl > /dev/null

echo "== 2/5 install Xray =="
bash <(curl -L --max-time 120 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

echo "== 3/5 firewall =="
ufw allow 443/tcp > /dev/null 2>&1 || true
# NOTE: also open TCP 443 in your provider's firewall/security-group panel.

echo "== 4/5 keys =="
UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIV=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
PUB=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
SID=$(openssl rand -hex 8)
IP=$(curl -s --max-time 10 https://api.ipify.org)
[ -z "$IP" ] && { echo "Could not detect server IP. Check internet."; exit 1; }

echo "== 5/5 config + start =="
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": [ "www.microsoft.com" ],
          "privateKey": "$PRIV",
          "shortIds": [ "$SID" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

echo "$PUB" > /root/vless-pubkey.txt
echo "$SID" > /root/vless-shortid.txt
chmod 600 /root/vless-pubkey.txt /root/vless-shortid.txt

systemctl enable xray > /dev/null 2>&1
systemctl restart xray
sleep 2
systemctl is-active --quiet xray \
  && echo "OK: xray is running" \
  || { echo "FAILED: xray did not start"; journalctl -u xray --no-pager -n 20; exit 1; }

echo ""
echo "==================== YOUR VLESS LINK ===================="
echo "vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUB}&sid=${SID}#GOLDENSKY-VPS"
echo "========================================================="
echo "Copy the link above -> GOLDENSKY -> Import -> LINK -> paste."
echo "Add more users later with:  bash add-vless-user.sh <name>"
