#!/bin/bash
# ============================================================
# setup-marzban-test.sh — Marzban TEST panel on a FRESH VPS
#
# Purpose: test Marzban's DAILY-RESET quota model
#   (one key, data_limit = 5GB, data_limit_reset_strategy = day)
# on a throwaway/new box BEFORE touching any production server.
#
# *** DO NOT RUN ON A PRODUCTION BOX ***
# Marzban takes over Xray-core completely. This script ABORTS if
# it sees x-ui / standalone xray / sing-box / hysteria / tuic /
# an existing Marzban on the box (override: FORCE=1, not advised).
#
# Layout (single box, phone-friendly):
#   Panel + subscriptions : https://<DOMAIN>:8443  (Caddy -> 127.0.0.1:8000)
#   VLESS + REALITY       : <DOMAIN/IP>:443        (flow xtls-rprx-vision)
#   Shadowsocks           : <DOMAIN/IP>:1080       (Marzban default inbound)
# Caddy needs TCP 80 free for the Let's Encrypt HTTP check.
# Provider firewall (Lightsail etc.): open TCP 80, 443, 8443, 1080
# and UDP 1080.
#
# Usage:
#   sudo bash setup-marzban-test.sh <DOMAIN>
#     e.g. sudo bash setup-marzban-test.sh marz.example.com
#   The DOMAIN's A record must already point to this server.
#
# Creates (saved to /root/marzban-test.txt, 0600):
#   - sudo admin "admin" (random password, /root/marzban-login.txt)
#   - user test5gb   : 5GB, reset=day, expire 30 days  (the real test)
#   - user burn100mb : 100MB, reset=day, expire 30 days (burn it fast,
#                      watch status -> limited, then Reset in panel
#                      or wait for the daily reset to revive it)
# Re-running: ABORTS if Marzban already exists (use `marzban` CLI).
# ============================================================
set -e

DOMAIN="${1:-}"
[ -n "$DOMAIN" ] || { echo "Usage: sudo bash setup-marzban-test.sh <DOMAIN>"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "Run as root (sudo)."; exit 1; }

echo "=== Marzban TEST installer (domain: $DOMAIN) ==="
grep PRETTY_NAME /etc/os-release 2>/dev/null || cat /etc/os-release 2>/dev/null || true

# ---------- package manager + prerequisites ----------
# v1.1: this kit first ran on a RHEL-family box (no apt-get, no python3)
# and died. Detect apt/dnf/yum and install prereqs with the right one.
if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
else
  echo "!! No apt-get / dnf / yum found — unsupported OS for this kit. Aborting."
  exit 1
fi
echo "-- package manager: $PKG"
pkg_install() {
  if [ "$PKG" = "apt" ]; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif [ "$PKG" = "dnf" ]; then
    dnf install -y "$@"
  else
    yum install -y "$@"
  fi
}
NEED=""
command -v python3 >/dev/null 2>&1 || NEED="$NEED python3"
command -v curl    >/dev/null 2>&1 || NEED="$NEED curl"
command -v openssl >/dev/null 2>&1 || NEED="$NEED openssl"
if [ "$PKG" = "apt" ]; then
  command -v ss    >/dev/null 2>&1 || NEED="$NEED iproute2"
  command -v pgrep >/dev/null 2>&1 || NEED="$NEED procps"
else
  command -v ss    >/dev/null 2>&1 || NEED="$NEED iproute"
  command -v pgrep >/dev/null 2>&1 || NEED="$NEED procps-ng"
fi
if [ -n "$NEED" ]; then
  echo "-- installing prerequisites:$NEED"
  pkg_install $NEED >/dev/null 2>&1 || pkg_install $NEED
fi
command -v python3 >/dev/null 2>&1 || { echo "!! python3 still missing after install attempt. Aborting."; exit 1; }

# ---------- safety / state detection ----------
# v1.3 RESUME: an earlier run of THIS kit got Marzban installed + configured
# (has .env, login file, and our REALITY inbound) but stopped later
# (e.g. at the Caddy step). Resume that state instead of aborting.
RESUME=0; CONFIGURED=0
if [ -f /opt/marzban/.env ] && [ -f /root/marzban-login.txt ]; then
  RESUME=1
  if grep -q "VLESS TCP REALITY" /var/lib/marzban/xray_config.json 2>/dev/null; then CONFIGURED=1; fi
  echo "-- RESUME mode: Marzban already installed by an earlier run of this kit (configured=$CONFIGURED)."
fi
if [ "$RESUME" != "1" ] && [ -d /opt/marzban ] && [ "${FORCE:-0}" != "1" ]; then
  if [ ! -f /opt/marzban/.env ] && [ ! -f /var/lib/marzban/db.sqlite3 ]; then
    # Partial install from an earlier failed run of THIS kit (the app never
    # started: no .env, no database, so no users/data can exist yet).
    BK="/opt/marzban.bak-$(date +%s)"
    echo "!! Found a PARTIAL Marzban install (no .env, no database)."
    echo "   Moving it to $BK and continuing fresh."
    mv /opt/marzban "$BK"
    if [ -d /var/lib/marzban ]; then mv /var/lib/marzban "/var/lib/marzban.bak-$(date +%s)"; fi
  else
    echo "!! /opt/marzban already exists — Marzban is already installed. Aborting."
    echo "   Manage it with the 'marzban' command instead of re-running this kit."
    exit 1
  fi
fi
if [ "$RESUME" != "1" ]; then
  FOUND=""
  for svc in x-ui sing-box hysteria gs-tuic gs-hy2-any; do
    systemctl is-active --quiet "$svc" 2>/dev/null && FOUND="$FOUND $svc"
  done
  pgrep -x xray >/dev/null 2>&1 && FOUND="$FOUND xray-process"
  [ -n "$FOUND" ] && [ "${FORCE:-0}" != "1" ] && {
    echo "!! Production-looking services are RUNNING on this box:$FOUND"
    echo "   Marzban would take over Xray and BREAK them. Aborting (nothing changed)."
    echo "   Run this kit on a NEW / empty VPS only."
    exit 1
  }
  for p in 80 443 8443 1080; do
    if ss -ltn | grep -q ":${p}[[:space:]]"; then
      echo "!! TCP $p is already in use. Aborting (nothing changed):"
      ss -ltnp | grep ":${p}[[:space:]]" || true
      exit 1
    fi
  done
fi
# ---------- public IP + domain check ----------
PUB_IP=$(curl -s -m 10 https://api.ipify.org || curl -s -m 10 https://ifconfig.me || true)
PUB_IP=$(printf '%s' "$PUB_IP" | tr -dc '0-9.')
[ -n "$PUB_IP" ] || { echo "!! Could not detect public IP. Aborting."; exit 1; }
echo "-- public IP: $PUB_IP"
HIT=$(python3 - "$DOMAIN" "$PUB_IP" <<'PYEOF'
import sys, json, urllib.request
name, ip = sys.argv[1], sys.argv[2]
try:
    req = urllib.request.Request("https://dns.google/resolve?name=%s&type=A" % name,
                                 headers={"Accept": "application/dns-json"})
    d = json.load(urllib.request.urlopen(req, timeout=10))
    ips = [a["data"] for a in d.get("Answer", []) if a.get("type") == 1]
    print("MATCH" if ip in ips else "NOMATCH:" + ",".join(ips))
except Exception as e:
    print("ERROR:%s" % e)
PYEOF
) || HIT=""
case "$HIT" in
  MATCH) echo "   OK: $DOMAIN -> $PUB_IP" ;;
  NOMATCH:*) echo "!! $DOMAIN resolves to ${HIT#NOMATCH:} — not this server ($PUB_IP)."
             echo "   Point the A record to $PUB_IP first, wait for DNS, then re-run. Aborting."
             exit 1 ;;
  *) echo "!! DNS check failed ($HIT) — continuing; HTTPS cert will fail if the domain is wrong." ;;
esac

# ---------- Docker pre-install for RHEL-family ----------
# v1.2: get.docker.com (used by the Marzban installer) REJECTS AlmaLinux
# ("Unsupported distribution 'almalinux'"). Install Docker ourselves from
# Docker's CentOS repo first — the Marzban installer then skips its own
# Docker step. The compose PLUGIN satisfies its detect_compose check.
if ! command -v docker >/dev/null 2>&1; then
  if [ "$PKG" = "dnf" ] || [ "$PKG" = "yum" ]; then
    echo "-- installing Docker from Docker's CentOS repo (get.docker.com does not support AlmaLinux)..."
    pkg_install dnf-plugins-core >/dev/null 2>&1 || pkg_install yum-utils >/dev/null 2>&1 || true
    if command -v dnf >/dev/null 2>&1; then
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      yum install -y --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl daemon-reload || true
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl restart docker || systemctl start docker
  fi
fi
if command -v docker >/dev/null 2>&1; then
  docker --version || true
  docker compose version >/dev/null 2>&1 || echo "WARNING: 'docker compose' plugin missing — Marzban installer may fail at the compose step."
fi

if [ "$CONFIGURED" = "1" ]; then
  ADMIN_USER=admin
  ADMIN_PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
  [ -n "$ADMIN_PASS" ] || { echo "!! Could not read the admin password from /root/marzban-login.txt. Aborting."; exit 1; }
  echo "-- RESUME: install + config already done. Continuing at the Caddy step."
  # make sure the app is actually up before continuing
  for i in $(seq 1 15); do curl -s -m 3 -o /dev/null http://127.0.0.1:8000/ && break; sleep 2; done
else
if [ "$RESUME" = "1" ]; then
  # Installed but never configured: no users can exist yet in this kit's
  # lifecycle (users are only created after the config step), so the
  # half-finished tree is moved aside and the install starts fresh.
  echo "-- RESUME: half-configured tree found; moving it aside and reinstalling."
  mv /opt/marzban "/opt/marzban.bak-$(date +%s)"
  if [ -d /var/lib/marzban ]; then mv /var/lib/marzban "/var/lib/marzban.bak-$(date +%s)"; fi
fi

# ---------- official Marzban install (SQLite), logs detached ----------
echo "-- installing Marzban (official script, SQLite)... this takes a few minutes"
curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o /tmp/marzban-official.sh
setsid bash /tmp/marzban-official.sh install > /root/marzban-install.log 2>&1 &
INST_PID=$!
UP=0
for i in $(seq 1 90); do
  sleep 10
  if ss -ltn 2>/dev/null | grep -q "127.0.0.1:8000\|0.0.0.0:8000\|\[::\]:8000" && [ -f /opt/marzban/.env ]; then UP=1; break; fi
  if ! kill -0 "$INST_PID" 2>/dev/null; then break; fi
done
# stop the installer (it ends by tailing logs; the containers keep running)
kill -- -"$INST_PID" 2>/dev/null || kill "$INST_PID" 2>/dev/null || true
sleep 2
if [ "$UP" != "1" ]; then
  echo "!! Marzban did not come up on :8000. Last install log lines:"
  tail -n 40 /root/marzban-install.log || true
  exit 1
fi
echo "OK: Marzban app is listening on :8000"
docker ps --format '{{.Names}} {{.Status}}' | grep -i marzban || true

# ---------- REALITY keys for the VLESS inbound ----------
echo "-- generating REALITY keypair (xray inside the Marzban container)..."
KEYS=$(docker compose -f /opt/marzban/docker-compose.yml -p marzban exec -T marzban xray x25519 2>/dev/null || true)
PRIV=$(printf '%s' "$KEYS" | grep -i "private" | awk '{print $NF}')
PUBK=$(printf '%s' "$KEYS" | grep -i "public" | awk '{print $NF}')
[ -n "$PRIV" ] && [ -n "$PUBK" ] || { echo "!! Could not generate REALITY keys. Got: $KEYS"; exit 1; }
SHORTID=$(openssl rand -hex 8)

# ---------- Xray config: VLESS+REALITY :443 + Shadowsocks :1080 ----------
cat > /var/lib/marzban/xray_config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "routing": { "rules": [ { "ip": ["geoip:private"], "outboundTag": "BLOCK", "type": "field" } ] },
  "inbounds": [
    {
      "tag": "VLESS TCP REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "$PRIV",
          "shortIds": ["$SHORTID"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "Shadowsocks TCP",
      "listen": "0.0.0.0",
      "port": 1080,
      "protocol": "shadowsocks",
      "settings": { "clients": [], "network": "tcp,udp" }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "DIRECT" },
    { "protocol": "blackhole", "tag": "BLOCK" }
  ]
}
EOF
echo "OK: xray_config.json written (VLESS REALITY :443, SS :1080)"

# ---------- .env: localhost app, public sub prefix, sudo admin ----------
ADMIN_USER=admin
ADMIN_PASS=$(head -c 15 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-20)
ENVF=/opt/marzban/.env
set_env() {  # set_env KEY VALUE  (handles commented or missing keys)
  if grep -q "^#* *$1 *=" "$ENVF"; then
    sed -i "s~^#* *$1 *=.*~$1 = \"$2\"~" "$ENVF"
  else
    echo "$1 = \"$2\"" >> "$ENVF"
  fi
}
set_env UVICORN_HOST "127.0.0.1"
set_env XRAY_SUBSCRIPTION_URL_PREFIX "https://$DOMAIN:8443"
grep -q "^SUDO_USERNAME" "$ENVF" || echo "SUDO_USERNAME = \"$ADMIN_USER\"" >> "$ENVF"
grep -q "^SUDO_PASSWORD" "$ENVF" || echo "SUDO_PASSWORD = \"$ADMIN_PASS\"" >> "$ENVF"
sed -i "s~^SUDO_USERNAME.*~SUDO_USERNAME = \"$ADMIN_USER\"~; s~^SUDO_PASSWORD.*~SUDO_PASSWORD = \"$ADMIN_PASS\"~" "$ENVF"
{
  echo "Marzban TEST panel"
  echo "  URL     : https://$DOMAIN:8443/dashboard/"
  echo "  Username: $ADMIN_USER"
  echo "  Password: $ADMIN_PASS"
  echo "  Server  : $PUB_IP ($DOMAIN)"
} > /root/marzban-login.txt
chmod 600 /root/marzban-login.txt
echo "-- restarting Marzban with the new config..."
# NOTE: plain `docker compose restart` does NOT re-read .env — must down+up.
marzban restart -n >/dev/null 2>&1 || docker compose -f /opt/marzban/docker-compose.yml -p marzban up -d --force-recreate marzban >/dev/null 2>&1 || true
for i in $(seq 1 30); do sleep 2; curl -s -m 3 -o /dev/null http://127.0.0.1:8000/ && break; done
fi

# ---------- Caddy on :8443 — as a Docker container (v1.3) ----------
# Host-package Caddy installs are OS-fragile (failed on AlmaLinux). Docker
# is already here for Marzban, so Caddy runs as a container with host
# networking: it binds :80 (ACME) + :8443 directly and proxies to the app.
echo "-- starting Caddy container (panel HTTPS on :8443)..."
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
https://$DOMAIN:8443 {
    reverse_proxy 127.0.0.1:8000
}
EOF
docker rm -f gs-caddy >/dev/null 2>&1 || true
docker run -d --name gs-caddy --restart unless-stopped --network host \
  -v /etc/caddy:/etc/caddy:ro,z \
  -v gs-caddy-data:/data \
  -v gs-caddy-config:/config \
  caddy:2 >/dev/null
sleep 3
docker ps --format '{{.Names}} {{.Status}}' | grep gs-caddy || {
  echo "!! Caddy container did not stay up. Logs:"
  docker logs --tail 30 gs-caddy || true
  exit 1
}
echo "-- waiting for HTTPS (cert issuing can take ~1 min)..."
HTTPS=0
for i in $(seq 1 30); do
  sleep 4
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "https://$DOMAIN:8443/dashboard/" || true)
  [ "$code" = "200" ] && { HTTPS=1; break; }
done
if [ "$HTTPS" != "1" ]; then
  echo "!! Panel HTTPS did not answer 200 at https://$DOMAIN:8443/dashboard/"
  echo "   Check: TCP 80 + 8443 open in the provider firewall? DNS right?"
  echo "   Caddy log: docker logs --tail 30 gs-caddy"
  echo "   (Marzban itself is up on 127.0.0.1:8000 — login details in /root/marzban-login.txt)"
  exit 1
fi
echo "OK: panel live at https://$DOMAIN:8443/dashboard/"

# Also try to create a REAL DB admin with the same credentials via the CLI
# (non-interactive: password comes from MARZBAN_ADMIN_PASSWORD inside the
# container). The SUDO_* env login works either way, so failure is not fatal.
docker compose -f /opt/marzban/docker-compose.yml -p marzban exec -T \
  -e MARZBAN_ADMIN_PASSWORD="$ADMIN_PASS" marzban \
  marzban-cli admin create --username "$ADMIN_USER" --sudo -tg 0 -dc 0 \
  >/root/marzban-admin-create.log 2>&1 || echo "NOTE: CLI admin create skipped/failed (SUDO env login still works) — see /root/marzban-admin-create.log"
# NOTE: SUDO_USERNAME/SUDO_PASSWORD stay in .env (root-only file) — in
# current Marzban they act as a virtual sudo login; removing them before
# a DB admin is confirmed could lock the panel. Login file has the creds.

# ---------- test users via the API ----------
echo "-- creating test users (test5gb daily-reset + burn100mb)..."
python3 - "$DOMAIN" "$ADMIN_USER" "$ADMIN_PASS" "$PUB_IP" <<'PYEOF' || echo "WARNING: API user creation failed — create the users by hand in the panel (Users -> Create: Data Limit 5GB, Reset Strategy = Day). Panel itself is fine."
import sys, json, time, urllib.request, urllib.parse
domain, user, pw, pub_ip = sys.argv[1:5]
base = "https://%s:8443" % domain

def req(method, path, data=None, token=None, form=False):
    body = None; headers = {}
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode(); headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode(); headers["Content-Type"] = "application/json"
    if token: headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(base + path, data=body, method=method, headers=headers)
    with urllib.request.urlopen(r, timeout=20) as resp:
        return json.load(resp)

tok = req("POST", "/api/admin/token", {"username": user, "password": pw}, form=True)["access_token"]
expire = int(time.time()) + 30 * 24 * 3600
out = {"panel": base + "/dashboard/", "users": {}}
import urllib.error
for name, limit in [("test5gb", 5 * 1024**3), ("burn100mb", 100 * 1024**2)]:
    try:
        u = req("POST", "/api/user", {
        "username": name,
        "proxies": {"vless": {"flow": "xtls-rprx-vision"}, "shadowsocks": {}},
        "inbounds": {"vless": ["VLESS TCP REALITY"], "shadowsocks": ["Shadowsocks TCP"]},
        "expire": expire,
        "data_limit": limit,
        "data_limit_reset_strategy": "day",
        "status": "active",
        }, token=tok)
    except urllib.error.HTTPError as e:
        if e.code != 409:
            raise
        u = req("GET", "/api/user/" + name, token=tok)  # exists: reuse
    out["users"][name] = {"data_limit": limit, "reset": "day",
                          "subscription_url": u.get("subscription_url", "")}
    print("created user:", name)
with open("/root/marzban-users.json", "w") as f:
    json.dump(out, f, indent=2)
print("OK")
PYEOF
chmod 600 /root/marzban-users.json 2>/dev/null || true

# ---------- fetch subscription content and extract raw links ----------
python3 - "$DOMAIN" <<'PYEOF' || echo "NOTE: subscription fetch check skipped/failed — open the user in the panel and copy its subscription link from there."
import json, base64, urllib.request
try:
    users = json.load(open("/root/marzban-users.json"))["users"]
except Exception:
    raise SystemExit(0)
links = []
for name, info in users.items():
    url = info.get("subscription_url") or ""
    if not url: continue
    r = urllib.request.Request(url, headers={"User-Agent": "v2rayNG/1.8.5"})
    raw = urllib.request.urlopen(r, timeout=20).read().decode(errors="ignore").strip()
    try:
        dec = base64.b64decode(raw + "=" * (-len(raw) % 4)).decode(errors="ignore")
    except Exception:
        dec = raw
    for line in dec.splitlines():
        if line.startswith(("vless://", "ss://")):
            links.append("%s  %s" % (name, line.strip()))
with open("/root/marzban-links.txt", "w") as f:
    f.write("\n".join(links) + "\n")
print("extracted %d raw links" % len(links))
PYEOF
chmod 600 /root/marzban-links.txt 2>/dev/null || true

# ---------- firewall (only the active one is touched) ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 8443/tcp >/dev/null 2>&1 || true
  ufw allow 1080/tcp >/dev/null 2>&1 || true
  ufw allow 1080/udp >/dev/null 2>&1 || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  for fp in 80/tcp 443/tcp 8443/tcp 1080/tcp 1080/udp; do
    firewall-cmd --permanent --add-port="$fp" >/dev/null 2>&1 || true
  done
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

# ---------- final summary ----------
{
  echo "Marzban TEST — DONE"
  echo "  Panel : https://$DOMAIN:8443/dashboard/  (login: /root/marzban-login.txt)"
  echo "  Server: $PUB_IP"
  echo "  Users : test5gb (5GB, reset=day) + burn100mb (100MB, reset=day)"
} > /root/marzban-test.txt
[ -f /root/marzban-links.txt ] && { echo ""; echo "Raw links:"; cat /root/marzban-links.txt; } >> /root/marzban-test.txt
chmod 600 /root/marzban-test.txt
echo ""
echo "==========================================================="
cat /root/marzban-test.txt
echo "==========================================================="
echo "Provider firewall: TCP 80, 443, 8443, 1080 + UDP 1080 must be open."
echo "Next: open the panel, log in, screenshot THIS final block and send it."
