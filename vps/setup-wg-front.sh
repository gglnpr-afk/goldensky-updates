#!/bin/bash
# setup-wg-front.sh — disposable WireGuard FRONT relay (run as root on the FRONT vps)
# Forwards UDP 500 to the hidden origin (FirstByte JP) with DNAT+MASQUERADE.
# Customers only ever see THIS box's IP; if it gets banned, replace this box,
# flip the wg subdomain's A record, and every key works again — origin untouched.
# Usage: bash setup-wg-front.sh [ORIGIN_IP] [PORT]   (defaults 132.243.30.145, 500)
set -e
[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }

ORIGIN="${1:-132.243.30.145}"
PORT="${2:-500}"

if ss -lun | grep -q ":$PORT "; then
  echo "UDP $PORT is already bound on this box (a local service is using it) - aborting."
  echo "A front box must be dedicated: nothing else may listen on UDP $PORT."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iptables curl >/dev/null

WANIF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$WANIF" ] || WANIF=eth0
echo "WAN interface: $WANIF  |  relay: UDP $PORT -> $ORIGIN:$PORT"

# --- apply-script (values baked in; idempotent, safe to re-run) ---
cat > /usr/local/bin/gs-wg-front-apply.sh <<EOF
#!/bin/bash
# WG front relay rules (installed by setup-wg-front.sh) — idempotent
iptables -t nat -C PREROUTING -i $WANIF -p udp --dport $PORT -j DNAT --to-destination $ORIGIN:$PORT 2>/dev/null || \
  iptables -t nat -A PREROUTING -i $WANIF -p udp --dport $PORT -j DNAT --to-destination $ORIGIN:$PORT
iptables -t nat -C POSTROUTING -o $WANIF -p udp -d $ORIGIN --dport $PORT -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o $WANIF -p udp -d $ORIGIN --dport $PORT -j MASQUERADE
iptables -C FORWARD -p udp -d $ORIGIN --dport $PORT -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -p udp -d $ORIGIN --dport $PORT -j ACCEPT
iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
EOF
chmod +x /usr/local/bin/gs-wg-front-apply.sh

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg-front.conf
sysctl -p /etc/sysctl.d/99-wg-front.conf >/dev/null

# --- persist across reboots via a systemd oneshot ---
cat > /etc/systemd/system/gs-wg-front.service <<'EOF'
[Unit]
Description=WG front relay rules (UDP 500 -> hidden origin)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gs-wg-front-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gs-wg-front >/dev/null 2>&1 || true
systemctl restart gs-wg-front
systemctl is-active gs-wg-front || { echo "ERROR: gs-wg-front failed to start"; journalctl -u gs-wg-front -n 20 --no-pager; exit 1; }

FRONTIP=$(curl -fsS4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo "=== WG FRONT READY ==="
echo "Front public IP : $FRONTIP"
iptables -t nat -L PREROUTING -n | grep "dpt:$PORT" || true
echo ""
echo "NEXT STEPS:"
echo "1) Cloudflare: set the WG subdomain A record to $FRONTIP (DNS only / grey cloud)"
echo "2) On the JP origin box:  echo <that-subdomain> > /etc/wireguard/host.txt"
echo "3) Mint a fresh key (add-wg test2) and phone-test it: exit must still be $ORIGIN"
