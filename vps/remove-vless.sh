#!/bin/bash
# ============================================================
# Remove the VLESS inbound from the GOLDENSKY VPS (keeps SS + VMess).
# Usage:  sudo bash remove-vless.sh
# After this, ALL VLESS keys stop working immediately.
# Backup of the config is saved to /root/ before changing.
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash remove-vless.sh"
  exit 1
fi

CFG=/usr/local/etc/xray/config.json

echo "== backup =="
BK="/root/xray-config-backup-$(date +%F-%H%M%S).json"
cp "$CFG" "$BK"
echo "backup: $BK"

echo "== removing VLESS inbound =="
python3 - <<'PYEOF'
import json
p = '/usr/local/etc/xray/config.json'
c = json.load(open(p))
before = len(c.get('inbounds', []))
c['inbounds'] = [i for i in c.get('inbounds', []) if i.get('protocol') != 'vless']
after = len(c['inbounds'])
print("inbounds: %d -> %d" % (before, after))
if before == after:
    print("NOTE: no VLESS inbound found - nothing changed")
with open(p, 'w') as f:
    json.dump(c, f, indent=2)
PYEOF

/usr/local/bin/xray -test -config "$CFG" > /dev/null \
  || { echo "ERROR: config validation failed."; exit 1; }

systemctl restart xray
sleep 1
systemctl is-active --quiet xray \
  && echo "OK: xray is running" \
  || { echo "FAILED: xray did not start"; exit 1; }

echo ""
echo "== remaining inbounds =="
python3 -c "import json; [print(' -', i.get('protocol'), 'port', i.get('port')) for i in json.load(open('$CFG'))['inbounds']]"
echo ""
echo "VLESS removed. Old VLESS keys no longer work."
echo "Shadowsocks (8388) + VMess (8080) unaffected."
