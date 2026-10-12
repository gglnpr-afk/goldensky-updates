#!/bin/bash
# ============================================================
# GOLDENSKY VPS setup — Shadowsocks + VMess (no VLESS).
# Fresh server one-shot. Run as root on Ubuntu 22.04.
# Usage:  sudo bash setup-ss-vmess.sh
# After: open TCP 8388 and 8080 in your provider's firewall.
# ============================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash setup-ss-vmess.sh"
  exit 1
fi

SS_PORT=8388
VMESS_PORT=8080
HOST="busterzone.mobi"

echo "== packages =="
apt-get update -qq
apt-get install -y -qq curl unzip python3 ufw > /dev/null

echo "== xray =="
if ! command -v xray > /dev/null 2>&1; then
  bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version v26.3.27
fi
mkdir -p /usr/local/etc/xray

echo "== keys =="
SS_PASS=$(xray uuid 2>/dev/null | tr -d '-' | head -c 24)
[ -z "$SS_PASS" ] && SS_PASS=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
VMESS_UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
[ -z "$VMESS_UUID" ] && { echo "ERROR: UUID generation failed."; exit 1; }

echo "== config =="
python3 - "$SS_PASS" "$VMESS_UUID" <<'PYEOF'
import json, sys
ss_pass, vmess_uuid = sys.argv[1], sys.argv[2]
c = {
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": 8388, "protocol": "shadowsocks",
      "settings": {"method": "aes-128-gcm", "password": ss_pass, "network": "tcp,udp"}
    },
    {
      "port": 8080, "protocol": "vmess",
      "settings": {"clients": [{"id": vmess_uuid, "alterId": 0}]},
      "streamSettings": {"network": "tcp"}
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
with open('/usr/local/etc/xray/config.json', 'w') as f:
    json.dump(c, f, indent=2)
print("config written")
PYEOF

/usr/local/bin/xray -test -config /usr/local/etc/xray/config.json > /dev/null \
  || { echo "ERROR: config validation failed."; exit 1; }

echo "== firewall =="
ufw allow ${SS_PORT}/tcp > /dev/null 2>&1 || true
ufw allow ${VMESS_PORT}/tcp > /dev/null 2>&1 || true
# NOTE: also open TCP 8388 + 8080 in your provider's firewall panel.

echo "== service =="
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF
systemctl daemon-reload
systemctl enable xray > /dev/null 2>&1 || true
systemctl restart xray
sleep 1
systemctl is-active --quiet xray \
  && echo "OK: xray is running" \
  || { echo "FAILED: xray did not start"; exit 1; }

echo ""
echo "==================== SS LINK (FREE) ===================="
SS_B64=$(echo -n "aes-128-gcm:${SS_PASS}" | base64 -w0)
SS_LINK="ss://${SS_B64}@${HOST}:${SS_PORT}#GOLDENSKY-SS2"
echo "$SS_LINK"
echo ""
echo "================== VMESS LINK (FREE) ==================="
VJSON=$(printf '{"v":"2","ps":"GOLDENSKY-FREE2","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none","host":"","path":"","tls":""}' "$HOST" "$VMESS_PORT" "$VMESS_UUID")
VMESS_LINK="vmess://$(echo -n "$VJSON" | base64 -w0)"
echo "$VMESS_LINK"
echo "========================================================="
for d in /home/ubuntu /root; do
  if [ -d "$d" ]; then
    echo "$SS_LINK" > "$d/my-ss.txt"; echo "$VMESS_LINK" > "$d/my-vmess.txt"
    chmod 644 "$d/my-ss.txt" "$d/my-vmess.txt"
  fi
done
echo "Links saved to my-ss.txt + my-vmess.txt (exact, copy-safe)."
echo "Send BOTH links to me and I'll bake them into the app."
