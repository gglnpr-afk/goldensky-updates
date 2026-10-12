#!/bin/bash
# ============================================================
# Remove one VLESS user from the GOLDENSKY VPS by name.
# Usage:  bash remove-vless-user.sh <name>
# Example: bash remove-vless-user.sh ko-aung
# Their key stops working immediately.
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash remove-vless-user.sh <name>"
  exit 1
fi

NAME=${1:-}
if [ -z "$NAME" ]; then
  echo "Usage: sudo bash remove-vless-user.sh <name>"
  echo "See names with: sudo bash list-vless-users.sh"
  exit 1
fi

# Find UUID from the name -> UUID mapping
UUID=""
if [ -f /root/vless-users.txt ]; then
  UUID=$(grep -m1 " $NAME " /root/vless-users.txt | awk '{print $1}')
fi
# Or accept a UUID directly
if [ -z "$UUID" ]; then
  case "$NAME" in
    ????????-????-????-????-????????????) UUID="$NAME" ;;
  esac
fi
if [ -z "$UUID" ]; then
  echo "User '$NAME' not found."
  echo "See names with: sudo bash list-vless-users.sh"
  exit 1
fi

python3 - "$UUID" <<'PYEOF'
import json, sys
uuid = sys.argv[1]
p = '/usr/local/etc/xray/config.json'
c = json.load(open(p))
clients = c['inbounds'][0]['settings']['clients']
before = len(clients)
c['inbounds'][0]['settings']['clients'] = [x for x in clients if x.get('id') != uuid]
after = len(c['inbounds'][0]['settings']['clients'])
json.dump(c, open(p, 'w'), indent=2)
print("removed" if after < before else "not in config", uuid)
PYEOF

# Remove from mapping file
if [ -f /root/vless-users.txt ]; then
  sed -i "/^$UUID /d" /root/vless-users.txt
fi

systemctl restart xray
sleep 1
echo "Done. Key for '$NAME' no longer works."
