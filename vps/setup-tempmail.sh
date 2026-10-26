#!/bin/bash
# GOLDENSKY Temp Mail — server setup (ADDITIVE: does not touch VPN services)
# Usage on the VPS (via Termius):
#   Tokyo (52.194.182.108):       sudo bash setup-tempmail.sh busterzone.mobi
#   Singapore (47.129.129.29):    sudo bash setup-tempmail.sh donatekey.realty
#   Multi-domain (one VPS, several mail domains; API host uses the FIRST domain):
#                                 sudo bash setup-tempmail.sh luciferdead.com luciferdead.com,secondfamilys.com
# Installs: Mailpit (SMTP catch-all :25, persistent DB, UNLIMITED retention)
#         + gsmail gateway (token-per-address API, 127.0.0.1:8090)
#         + Caddy (HTTPS at https://mailapi.<domain>)
# Safe to re-run: it reinstalls/updates its own pieces only.
set -e
DOMAIN="${1:-}"
DOMAINS="${2:-$DOMAIN}"
if [ -z "$DOMAIN" ]; then echo "Usage: sudo bash setup-tempmail.sh <primary-domain> [all-domains-comma-separated]"; exit 1; fi
if [ "$(id -u)" != "0" ]; then echo "Run with sudo"; exit 1; fi
API_HOST="mailapi.$DOMAIN"
echo "== GOLDENSKY Temp Mail setup for $DOMAIN (API: https://$API_HOST) =="

for p in 25 80 443; do
  if ss -tlnp 2>/dev/null | grep -q ":$p "; then echo "NOTE: port $p already in use — check before continuing"; fi
done

dl() { # dl <github repo> <asset-name-substring> <dest>
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep browser_download_url | grep "$2" | head -1 | cut -d'"' -f4)
  if [ -z "$url" ]; then echo "Download URL not found for $1 ($2)"; exit 1; fi
  echo "Downloading $url"
  curl -fsSL "$url" -o /tmp/dl.tar.gz
  tar -xzf /tmp/dl.tar.gz -C /tmp/dl_extract
}
mkdir -p /tmp/dl_extract /var/lib/mailpit /var/lib/gsmail /opt/gsmail

echo "-- Mailpit --"
rm -rf /tmp/dl_extract; mkdir -p /tmp/dl_extract
dl axllent/mailpit "linux-amd64.tar.gz"
install -m755 /tmp/dl_extract/mailpit /usr/local/bin/mailpit
cat > /etc/systemd/system/mailpit.service <<'EOF'
[Unit]
Description=Mailpit (GOLDENSKY Temp Mail store)
After=network.target
[Service]
Environment=MP_MAX_MESSAGES=0
Environment=MP_DATABASE=/var/lib/mailpit/mailpit.db
Environment=MP_SMTP_BIND_ADDR=0.0.0.0:25
Environment=MP_UI_BIND_ADDR=127.0.0.1:8025
Environment=MP_MAX_MESSAGE_SIZE=25
ExecStart=/usr/local/bin/mailpit --smtp 0.0.0.0:25 --listen 127.0.0.1:8025 --database /var/lib/mailpit/mailpit.db --max 0 --max-message-size 25
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

echo "-- Gateway --"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/gateway.py" ]; then
  install -m755 "$SCRIPT_DIR/gateway.py" /opt/gsmail/gateway.py
else
  echo "gateway.py not beside script — downloading from GitHub"
  curl -fsSL "https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/gateway.py" -o /opt/gsmail/gateway.py
  chmod 755 /opt/gsmail/gateway.py
fi
cat > /etc/systemd/system/gsmail.service <<EOF
[Unit]
Description=GOLDENSKY Temp Mail gateway API
After=network.target mailpit.service
Requires=mailpit.service
[Service]
Environment=GS_DOMAINS=$DOMAINS
Environment=GS_DB=/var/lib/gsmail/gateway.db
Environment=GS_PORT=8090
ExecStart=/usr/bin/python3 /opt/gsmail/gateway.py
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

echo "-- Caddy --"
if ! command -v caddy >/dev/null 2>&1; then
  rm -rf /tmp/dl_extract; mkdir -p /tmp/dl_extract
  dl caddyserver/caddy "linux_amd64.tar.gz"
  install -m755 /tmp/dl_extract/caddy /usr/local/bin/caddy
fi
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
$API_HOST {
    reverse_proxy 127.0.0.1:8090
}
EOF
cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy (GOLDENSKY Temp Mail HTTPS)
After=network.target
[Service]
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mailpit gsmail caddy
sleep 2
echo
echo "== Status =="
systemctl --no-pager -n0 status mailpit gsmail caddy 2>/dev/null | grep -E "●|Active:" || true
echo
curl -fsS http://127.0.0.1:8090/health && echo
echo
echo "DONE for $DOMAINS"
echo "Next steps:"
echo " 1) Lightsail panel -> this instance -> Networking: open TCP 25, 80, 443"
echo " 2) Cloudflare DNS for $DOMAIN (DNS only / grey cloud):"
echo "      A   mail     -> this VPS public IP"
echo "      MX  @        -> mail.$DOMAIN   (priority 10)"
echo "      A   mailapi  -> this VPS public IP"
echo " 2b) For EACH extra domain in '$DOMAINS' (Cloudflare DNS, grey cloud):"
echo "      MX  @        -> mail.$DOMAIN   (priority 10)   [mail lands on this same VPS]"
echo " 3) Test: open https://$API_HOST/health in a browser (should show ok:true)"
echo "Retention: UNLIMITED (no auto-delete). Existing VPN services untouched."
