#!/bin/bash
# ============================================================
# Add a VMess user to the GOLDENSKY VPS (TCP, port 8080).
# Usage:  sudo bash add-vmess.sh <name>
# Example: sudo bash add-vmess.sh ko-aung
# NOTE: open TCP 8080 in your provider's firewall panel too
# (e.g. Lightsail Networking -> Add rule).
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash add-vmess.sh <name>"
  exit 1
fi

NAME=${1:-vmess-user}
VMESS_PORT=8080
HOST="musiczone.mobi"
UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
[ -z "$UUID" ] && { echo "ERROR: UUID generation failed."; exit 1; }

echo "== firewall =="
ufw allow ${VMESS_PORT}/tcp > /dev/null 2>&1 || true
# NOTE: also open TCP 8080 in your provider's firewall panel.

echo "== config =="
python3 - "$UUID" <<'PYEOF'
import json, sys
uuid = sys.argv[1]
p = '/usr/local/etc/xray/config.json'
c = json.load(open(p))
vmess = None
for i in c.get('inbounds', []):
    if i.get('protocol') == 'vmess':
        vmess = i
        break
if vmess is None:
    vmess = {
        "port": 8080,
        "protocol": "vmess",
        "settings": {"clients": []},
        "streamSettings": {"network": "tcp"}
    }
    c['inbounds'].append(vmess)
    print("VMess inbound added on port 8080")
clients = vmess['settings']['clients']
if not any(x.get('id') == uuid for x in clients):
    clients.append({"id": uuid, "alterId": 0})
    print("user added:", uuid)
else:
    print("user already exists")
with open(p, 'w') as f:
    json.dump(c, f, indent=2)
PYEOF

/usr/local/bin/xray -test -config /usr/local/etc/xray/config.json > /dev/null \
  || { echo "ERROR: config validation failed."; exit 1; }

# Record user
echo "$UUID $NAME $(date +%F)" >> /root/vmess-users.txt
chmod 600 /root/vmess-users.txt 2>/dev/null || true

systemctl restart xray
sleep 1
systemctl is-active --quiet xray \
  && echo "OK: xray is running" \
  || { echo "FAILED: xray did not start"; exit 1; }

echo ""
echo "==================== VMESS LINK FOR ${NAME} ===================="
VJSON=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none","host":"","path":"","tls":""}' "$NAME" "$HOST" "$VMESS_PORT" "$UUID")
LINK="vmess://$(echo -n "$VJSON" | base64 -w0)"
echo "$LINK"
echo "================================================================"
for d in /home/ubuntu /root; do
  if [ -d "$d" ]; then echo "$LINK" > "$d/my-vmess-$NAME.txt"; chmod 644 "$d/my-vmess-$NAME.txt"; fi
done
echo "Link also saved to my-vmess-$NAME.txt (exact, copy-safe)."
echo "GOLDENSKY -> Import -> FILE -> pick the file."
