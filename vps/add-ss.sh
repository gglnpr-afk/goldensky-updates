#!/bin/bash
# Add Shadowsocks inbound to existing Xray config (GOLDENSKY VPS)
# Usage: sudo bash add-ss.sh
set -e

CONFIG="/usr/local/etc/xray/config.json"
[ ! -f "$CONFIG" ] && { echo "ERROR: $CONFIG not found. Run setup-vps.sh first."; exit 1; }

# Generate SS password (16 random bytes, base64)
SS_PASS=$(openssl rand -base64 16)
SS_PORT=8388
SS_METHOD="aes-128-gcm"

# Get server IP
IP=$(curl -s --max-time 10 https://api.ipify.org || curl -s --max-time 10 https://ifconfig.me)
[ -z "$IP" ] && { echo "Could not detect server IP."; exit 1; }

# Backup
cp "$CONFIG" "${CONFIG}.bak.$(date +%s)"

# Add SS inbound using python3 (reliable JSON edit)
python3 << PYEOF
import json
with open("$CONFIG") as f:
    cfg = json.load(f)
# Remove old SS inbound if exists (re-run safe)
cfg["inbounds"] = [i for i in cfg.get("inbounds", []) if i.get("protocol") != "shadowsocks"]
cfg["inbounds"].append({
    "port": $SS_PORT,
    "protocol": "shadowsocks",
    "settings": {
        "method": "$SS_METHOD",
        "password": "$SS_PASS",
        "network": "tcp,udp"
    }
})
with open("$CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
print("SS inbound added on port $SS_PORT")
PYEOF

# Validate + restart
/usr/local/bin/xray -test -config "$CONFIG" > /dev/null || { echo "ERROR: invalid config, restored backup"; exit 1; }
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "FAILED: xray did not start"; exit 1; }

# Build ss:// link (method:password base64url, no padding)
SS_USERINFO=$(echo -n "${SS_METHOD}:${SS_PASS}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
LINK="ss://${SS_USERINFO}@${IP}:${SS_PORT}#GOLDENSKY-SS"

echo ""
echo "OK: Shadowsocks is running"
echo ""
echo "$LINK"
echo ""
echo "$LINK" > /home/ubuntu/my-ss.txt 2>/dev/null || true
echo "(also saved to /home/ubuntu/my-ss.txt)"
