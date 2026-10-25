#!/bin/bash
# GOLDENSKY Temp Mail — SG fix ONLY (run on the Singapore VPS, 47.129.129.29)
# Problem: Caddy cannot start because port 443 = leftover stunnel4 (from the
# GOLDENSKY-SG-SSL feature the user removed on 2026-10-19; no customer uses it)
# and port 80 = python3 ATOM WS bridge (ACTIVE service — never touched).
# Fix: stop+disable stunnel4 (frees 443), Caddy listens on 443 only,
# HTTP challenge disabled (TLS-ALPN on 443), HTTP port moved to 8099.
set -e
if [ "$(id -u)" != "0" ]; then echo "Run with sudo"; exit 1; fi
echo "== Before =="
ss -tlnp | grep -E ':(80|443) ' || true

echo "-- Stopping leftover stunnel4 (SG-SSL was removed 2026-10-19; unused) --"
systemctl stop stunnel4 2>/dev/null || true
systemctl disable stunnel4 2>/dev/null || true

echo "-- Writing Caddyfile (443 only, TLS-ALPN challenge) --"
cat > /etc/caddy/Caddyfile <<'EOF'
{
    http_port 8099
    auto_https disable_redirects
}

mailapi.donatekey.realty {
    tls {
        issuer acme {
            disable_http_challenge
        }
    }
    reverse_proxy 127.0.0.1:8090
}
EOF
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile
systemctl restart caddy
sleep 2
echo
echo "== Status =="
systemctl --no-pager -n0 status mailpit gsmail caddy 2>/dev/null | grep -E "●|Active:" || true
echo
ss -tlnp | grep -E ':(25|80|443) ' || true
curl -fsS http://127.0.0.1:8090/health && echo
echo
echo "DONE. Caddy is on 443 now. The certificate is issued automatically"
echo "once Cloudflare DNS (mailapi -> this VPS) and the Lightsail 443 rule exist."
echo "ATOM (port 80 python) and all VPN services were NOT touched."
