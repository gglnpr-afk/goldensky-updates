#!/bin/bash
# ============================================================
# Add a plain VLESS user (TCP, no TLS, no REALITY) — simple and reliable.
# Usage:  sudo bash add-vless-plain.sh <name> <domain>
# Example: sudo bash add-vless-plain.sh ko-aung musiczone.mobi
# NOTE: open TCP 25574 in your provider's firewall panel too.
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash add-vless-plain.sh <name> <domain>"
  exit 1
fi

NAME=${1:-vless-user}
HOST=${2:-}
if [ -z "$HOST" ]; then
  echo "Usage: sudo bash add-vless-plain.sh <name> <domain>"
  echo "Example: sudo bash add-vless-plain.sh ko-aung musiczone.mobi"
  exit 1
fi

VLESS_PORT=25574
UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
[ -z "$UUID" ] && { echo "ERROR: UUID generation failed."; exit 1; }

echo "== firewall =="
ufw allow ${VLESS_PORT}/tcp > /dev/null 2>&1 || true
# NOTE: also open TCP 25574 in your provider's firewall panel.

echo "== config =="
python3 - "$UUID" <<'PYEOF'
import json, sys
uuid = sys.argv[1]
p = '/usr/local/etc/xray/config.json'
c = json.load(open(p))
vless = None
for i in c.get('inbounds', []):
    if i.get('protocol') == 'vless':
        vless = i
        break
if vless is None:
    vless = {
        "port": 25574,
        "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "streamSettings": {"network": "tcp"}
    }
    c['inbounds'].append(vless)
    print("VLESS inbound added on port 25574 (plain TCP)")
clients = vless['settings']['clients']
if not any(x.get('id') == uuid for x in clients):
    clients.append({"id": uuid})
    print("user added:", uuid)
else:
    print("user already exists")
with open(p, 'w') as f:
    json.dump(c, f, indent=2)
PYEOF

/usr/local/bin/xray -test -config /usr/local/etc/xray/config.json > /dev/null \
  || { echo "ERROR: config validation failed."; exit 1; }

# Record user
echo "$UUID $NAME $(date +%F)" >> /root/vless-users.txt
chmod 600 /root/vless-users.txt 2>/dev/null || true

systemctl restart xray
sleep 1
systemctl is-active --quiet xray \
  && echo "OK: xray is running" \
  || { echo "FAILED: xray did not start"; exit 1; }

echo ""
echo "==================== VLESS LINK FOR ${NAME} ===================="
LINK="vless://${UUID}@${HOST}:${VLESS_PORT}?security=none&encryption=none&headerType=none&type=tcp#${NAME}"
echo "$LINK"
echo "================================================================"
for d in /home/ubuntu /root; do
  if [ -d "$d" ]; then echo "$LINK" > "$d/my-vless-$NAME.txt"; chmod 644 "$d/my-vless-$NAME.txt"; fi
done
echo "Link also saved to my-vless-$NAME.txt (exact, copy-safe)."
echo "GOLDENSKY -> Import -> LINK -> paste."
