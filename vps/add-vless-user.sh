#!/bin/bash
# ============================================================
# Add one VLESS user to the GOLDENSKY VPS and print their link.
# Usage:  bash add-vless-user.sh <name>
# Example: bash add-vless-user.sh ko-aung
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash add-vless-user.sh <name>"
  exit 1
fi

NAME=${1:-user}
UUID=$(xray uuid)
PUB=$(cat /root/vless-pubkey.txt)
SID=$(cat /root/vless-shortid.txt)
IP=$(curl -s --max-time 10 https://api.ipify.org)

python3 - "$UUID" <<'PYEOF'
import json, sys
uuid = sys.argv[1]
p = '/usr/local/etc/xray/config.json'
c = json.load(open(p))
clients = c['inbounds'][0]['settings']['clients']
if not any(x.get('id') == uuid for x in clients):
    clients.append({"id": uuid, "flow": "xtls-rprx-vision"})
    json.dump(c, open(p, 'w'), indent=2)
    print("user added:", uuid)
else:
    print("user already exists")
PYEOF

systemctl restart xray
sleep 1

echo ""
echo "==================== LINK FOR ${NAME} ===================="
echo "vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUB}&sid=${SID}#${NAME}"
echo "========================================================="
