#!/bin/bash
# ============================================================
# setup-marzban-aws.sh — Marzban panel + core, REBUILT on AWS JP
#
# The old Marzban box (83.147.235.168) is gone (provider ban), so this
# kit installs a FRESH Marzban on the AWS JP box (52.194.182.108),
# which already runs production services. User data from the old
# panel is NOT migrated (fresh users via the Telegram bot).
#
# Layout on THIS box (different from the old box — read carefully):
#   Panel + subscriptions : https://marz.gloriafreeproton.io
#                           (the EXISTING host Caddy on TCP 443,
#                            one site block is APPENDED — see below)
#   Panel app (backend)   : 127.0.0.1:8000 (Docker, localhost only)
#   VLESS (PLAIN, no TLS) : marz.gloriafreeproton.io:8443  TCP
#   Shadowsocks           : marz.gloriafreeproton.io:1080  TCP+UDP
#
# Why these ports:
#   - TCP 443 is Caddy's (Temp Mail gateway mailapi.busterzone.mobi
#     is LIVE on it) — the panel VLESS therefore moves to TCP 8443.
#     UDP 8443 is HY2; TCP and UDP are different worlds, no clash.
#   - UDP 443 is TUIC, TCP 8388/8080/25574 are the Xray sales stack.
#     This kit NEVER touches them and does NOT stop any service.
#
# Caddy handling (the delicate part):
#   - NO second Caddy is installed. ONE site block for
#     marz.gloriafreeproton.io (reverse_proxy 127.0.0.1:8000) is
#     APPENDED to /etc/caddy/Caddyfile.
#   - Timestamped backup first; `caddy validate` must pass BEFORE
#     any reload; if the reload fails or the Temp Mail gateway
#     health check regresses, the backup is restored automatically.
#   - The existing global block (incl. `servers { protocols h1 h2 }`,
#     HTTP/3 off for TUIC) and the mailapi site are left untouched.
#
# Inbound tags keep their historical names ("VLESS TCP REALITY",
# "Shadowsocks TCP") because the Telegram bot references them.
# The VLESS inbound is PLAIN (security none) — REALITY failed the
# phone<->server path in Nov 2026 field tests; the tag is only a
# label. Links therefore show security=none, port 8443.
#
# Prerequisites (do these BEFORE running):
#   1. marz.gloriafreeproton.io A record -> THIS box (52.194.182.108),
#      DNS only, and DNS has propagated (the kit checks and aborts
#      if the domain points somewhere else).
#   2. Provider firewall (Lightsail): TCP 80, 443, 8443, 1080 and
#      UDP 1080 open (80/443 already are, for the existing Caddy).
#
# Usage:
#   sudo bash setup-marzban-aws.sh [DOMAIN]   (default marz.gloriafreeproton.io)
#
# Creates:
#   - sudo admin "admin" (random password -> /root/marzban-login.txt, 0600)
#   - probe user "awsprobe" (5GB, reset=day, 30 days) whose links are
#     verified (domain + ports) and saved to /root/marzban-aws.txt
# Re-running: resumes its own half-finished state; ABORTS on a
# foreign Marzban install instead of overwriting it.
# ============================================================
set -euo pipefail

DOMAIN="${1:-marz.gloriafreeproton.io}"
[ "$(id -u)" = "0" ] || { echo "Run as root (sudo)."; exit 1; }

echo "=== Marzban AWS installer (domain: $DOMAIN) ==="
grep PRETTY_NAME /etc/os-release 2>/dev/null || cat /etc/os-release 2>/dev/null || true

# ---------- prerequisites (Ubuntu / apt only — this kit targets AWS JP) ----------
command -v apt-get >/dev/null 2>&1 || { echo "!! apt-get not found — this kit targets the Ubuntu AWS box. Aborting."; exit 1; }
NEED=""
command -v python3 >/dev/null 2>&1 || NEED="$NEED python3"
command -v curl    >/dev/null 2>&1 || NEED="$NEED curl"
command -v openssl >/dev/null 2>&1 || NEED="$NEED openssl"
command -v ss      >/dev/null 2>&1 || NEED="$NEED iproute2"
command -v pgrep   >/dev/null 2>&1 || NEED="$NEED procps"
if [ -n "$NEED" ]; then
  echo "-- installing prerequisites:$NEED"
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $NEED
fi
command -v python3 >/dev/null 2>&1 || { echo "!! python3 still missing after install attempt. Aborting."; exit 1; }

# ---------- safety / state detection ----------
# RESUME: an earlier run of THIS kit installed + configured Marzban
# (has .env, login file, and OUR :8443 inbound) but stopped later
# (e.g. at the Caddy step). Resume that state instead of aborting.
RESUME=0; CONFIGURED=0
if [ -f /opt/marzban/.env ] && [ -f /root/marzban-login.txt ]; then
  if grep -q '"port": 8443' /var/lib/marzban/xray_config.json 2>/dev/null; then
    RESUME=1; CONFIGURED=1
    echo "-- RESUME mode: Marzban already installed + configured by this kit. Continuing at the API/Caddy steps."
  else
    echo "!! /opt/marzban exists with a login file, but its Xray config is NOT this kit's (:8443 missing)."
    echo "   Refusing to overwrite a foreign Marzban install. Aborting (nothing changed)."
    exit 1
  fi
fi
if [ "$RESUME" != "1" ] && [ -d /opt/marzban ]; then
  if [ ! -f /opt/marzban/.env ] && [ ! -f /var/lib/marzban/db.sqlite3 ]; then
    # Partial install from an earlier failed run (the app never
    # started: no .env, no database, so no users/data can exist yet).
    BK="/opt/marzban.bak-$(date +%s)"
    echo "!! Found a PARTIAL Marzban install (no .env, no database)."
    echo "   Moving it to $BK and continuing fresh."
    mv /opt/marzban "$BK"
    if [ -d /var/lib/marzban ]; then mv /var/lib/marzban "/var/lib/marzban.bak-$(date +%s)"; fi
  else
    echo "!! /opt/marzban already exists — a Marzban is already installed. Aborting."
    echo "   Manage it with the 'marzban' command instead of re-running this kit."
    exit 1
  fi
fi

# Coexistence NOTE (NOT an abort — unlike the fresh-box test kit):
# this box is SUPPOSED to run the sales Xray, TUIC, HY2 and Caddy.
echo "-- production neighbours on this box (expected, left untouched):"
for svc in caddy gs-tuic; do
  systemctl is-active --quiet "$svc" 2>/dev/null && echo "   $svc: active" || true
done
pgrep -x xray >/dev/null 2>&1 && echo "   xray process: running (sales stack)" || true
pgrep -x hysteria >/dev/null 2>&1 && echo "   hysteria process: running (HY2)" || true
pgrep -x sing-box >/dev/null 2>&1 && echo "   sing-box process: running (TUIC)" || true

if [ "$RESUME" != "1" ]; then
  # Port pre-flight — abort if OUR ports are held by something else.
  # (TCP 443 is intentionally NOT in this list: Caddy owns it.)
  for p in 8443 1080; do
    if ss -ltn | grep -q ":${p}[[:space:]]"; then
      echo "!! TCP $p is already in use. Aborting (nothing changed):"
      ss -ltnp | grep ":${p}[[:space:]]" || true
      exit 1
    fi
  done
  if ss -lun | grep -q ":1080[[:space:]]"; then
    echo "!! UDP 1080 is already in use. Aborting (nothing changed):"
    ss -lunp | grep ":1080[[:space:]]" || true
    exit 1
  fi
  if ss -ltn | grep -q "127.0.0.1:8000[[:space:]]"; then
    echo "!! 127.0.0.1:8000 is already in use (needed by the Marzban app). Aborting (nothing changed):"
    ss -ltnp | grep ":8000[[:space:]]" || true
    exit 1
  fi
  echo "OK: TCP 8443, TCP/UDP 1080, 127.0.0.1:8000 are free"
fi

# ---------- public IP + domain check ----------
# NOTE: curl -4 — plain curl on this box egresses over IPv6 and the
# old kits' IPv4-mangling would produce garbage here.
PUB_IP=$(curl -4 -s -m 10 https://api.ipify.org || curl -4 -s -m 10 https://ifconfig.me || true)
PUB_IP=$(printf '%s' "$PUB_IP" | tr -dc '0-9.')
[ -n "$PUB_IP" ] || { echo "!! Could not detect public IPv4. Aborting."; exit 1; }
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

# ---------- Docker (Ubuntu: get.docker.com works; Marzban needs it too) ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "-- installing Docker (get.docker.com)..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker || { echo "!! Docker did not start. Aborting."; exit 1; }
fi
docker --version || true
docker compose version >/dev/null 2>&1 || echo "WARNING: 'docker compose' plugin missing — Marzban installer may fail at the compose step."

if [ "$CONFIGURED" = "1" ]; then
  ADMIN_USER=admin
  ADMIN_PASS=$(grep "Password:" /root/marzban-login.txt | awk '{print $NF}')
  [ -n "$ADMIN_PASS" ] || { echo "!! Could not read the admin password from /root/marzban-login.txt. Aborting."; exit 1; }
  echo "-- RESUME: install + config already done. Continuing."
  for i in $(seq 1 15); do curl -s -m 3 -o /dev/null http://127.0.0.1:8000/ && break; sleep 2; done
else

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

# ---------- Xray config: PLAIN VLESS TCP :8443 + Shadowsocks :1080 ----------
# Tag names are historical (the bot references them). The VLESS
# inbound is PLAIN — no REALITY keys are generated on purpose.
cat > /var/lib/marzban/xray_config.json <<'EOF'
{
  "log": { "loglevel": "warning" },
  "routing": { "rules": [ { "ip": ["geoip:private"], "outboundTag": "BLOCK", "type": "field" } ] },
  "inbounds": [
    {
      "tag": "VLESS TCP REALITY",
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "none" },
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
echo "OK: xray_config.json written (PLAIN VLESS TCP :8443, SS :1080)"

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
set_env XRAY_SUBSCRIPTION_URL_PREFIX "https://$DOMAIN"
grep -q "^SUDO_USERNAME" "$ENVF" || echo "SUDO_USERNAME = \"$ADMIN_USER\"" >> "$ENVF"
grep -q "^SUDO_PASSWORD" "$ENVF" || echo "SUDO_PASSWORD = \"$ADMIN_PASS\"" >> "$ENVF"
sed -i "s~^SUDO_USERNAME.*~SUDO_USERNAME = \"$ADMIN_USER\"~; s~^SUDO_PASSWORD.*~SUDO_PASSWORD = \"$ADMIN_PASS\"~" "$ENVF"
{
  echo "Marzban panel (AWS JP)"
  echo "  URL     : https://$DOMAIN/dashboard/"
  echo "  Username: $ADMIN_USER"
  echo "  Password: $ADMIN_PASS"
  echo "  Server  : $PUB_IP ($DOMAIN)"
} > /root/marzban-login.txt
chmod 600 /root/marzban-login.txt
echo "-- restarting Marzban with the new config..."
# NOTE: plain `docker compose restart` does NOT re-read .env — must down+up.
marzban restart -n >/dev/null 2>&1 || docker compose -f /opt/marzban/docker-compose.yml -p marzban up -d --force-recreate marzban >/dev/null 2>&1 || true
for i in $(seq 1 30); do sleep 2; curl -s -m 3 -o /dev/null http://127.0.0.1:8000/ && break; done
curl -s -m 3 -o /dev/null http://127.0.0.1:8000/ || { echo "!! Marzban app did not come back on 127.0.0.1:8000. Check: docker ps / marzban status"; exit 1; }
echo "OK: Marzban app is up on 127.0.0.1:8000"
fi

# ---------- API: hosts -> domain, DB admin, probe user + link check ----------
echo "-- configuring hosts + probe user via the API..."
python3 - "$DOMAIN" "$ADMIN_PASS" <<'PYEOF' || echo "WARNING: API setup step failed — panel itself is up; fix hosts in the panel (Settings -> Hosts) and check links there."
import sys, json, time, urllib.request, urllib.parse, urllib.error
domain, pw = sys.argv[1], sys.argv[2]
base = "http://127.0.0.1:8000"

def req(method, path, data=None, tok=None, form=False):
    body = None; headers = {}
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode(); headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode(); headers["Content-Type"] = "application/json"
    if tok: headers["Authorization"] = "Bearer " + tok
    r = urllib.request.Request(base + path, data=body, method=method, headers=headers)
    with urllib.request.urlopen(r, timeout=25) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else {}

tok = req("POST", "/api/admin/token", {"username": "admin", "password": pw}, form=True)["access_token"]
print("OK: panel API login")

# hosts: every generated link must use the domain, not the raw IP
hosts = req("GET", "/api/hosts", tok=tok)
n = 0
for tag, lst in hosts.items():
    for h in lst:
        if h.get("address") != domain:
            h["address"] = domain; n += 1
if n:
    req("PUT", "/api/hosts", hosts, tok=tok)
print("OK: hosts point at %s (%d changed)" % (domain, n))

# probe user (also the owner's first test key on the new panel)
expire = int(time.time()) + 30 * 24 * 3600
try:
    u = req("POST", "/api/user", {
        "username": "awsprobe",
        "proxies": {"vless": {}, "shadowsocks": {}},
        "inbounds": {"vless": ["VLESS TCP REALITY"], "shadowsocks": ["Shadowsocks TCP"]},
        "expire": expire,
        "data_limit": 5 * 1024**3,
        "data_limit_reset_strategy": "day",
        "status": "active",
        "note": "AWS rebuild probe (setup-marzban-aws.sh)",
    }, tok=tok)
except urllib.error.HTTPError as e:
    if e.code != 409:
        raise
    u = req("GET", "/api/user/awsprobe", tok=tok)  # exists: reuse

links = u.get("links") or []
vl = next((l for l in links if l.startswith("vless://")), "")
ss = next((l for l in links if l.startswith("ss://")), "")
assert vl, "no VLESS link generated"
assert ("@" + domain + ":8443") in vl, "VLESS link wrong host/port: " + vl
assert "security=none" in vl and "pbk=" not in vl, "VLESS link is not PLAIN: " + vl
assert ss, "no SS link generated"
assert ("@" + domain + ":1080") in ss, "SS link wrong host/port: " + ss
sub = u.get("subscription_url") or ""
if sub and not sub.startswith("http"):
    sub = "https://" + domain + sub
with open("/root/marzban-aws-links.txt", "w") as f:
    f.write("VLESS: %s\nSS: %s\nSUB: %s\n" % (vl, ss, sub))
print("VERIFY OK: probe links are PLAIN, on %s, VLESS :8443 + SS :1080" % domain)
PYEOF
chmod 600 /root/marzban-aws-links.txt 2>/dev/null || true

# Also try to create a REAL DB admin with the same credentials via the CLI
# (non-interactive: password comes from MARZBAN_ADMIN_PASSWORD inside the
# container). The SUDO_* env login works either way, so failure is not fatal.
docker compose -f /opt/marzban/docker-compose.yml -p marzban exec -T \
  -e MARZBAN_ADMIN_PASSWORD="$ADMIN_PASS" marzban \
  marzban-cli admin create --username "$ADMIN_USER" --sudo -tg 0 -dc 0 \
  >/root/marzban-admin-create.log 2>&1 || echo "NOTE: CLI admin create skipped/failed (SUDO env login still works) — see /root/marzban-admin-create.log"

# ---------- Caddy: APPEND one site block to the EXISTING host Caddy ----------
echo "-- adding the Marzban site to the existing Caddy..."
CF=/etc/caddy/Caddyfile
CADDY=$(command -v caddy || true)
[ -x "$CADDY" ] || CADDY=/usr/local/bin/caddy
[ -x "$CADDY" ] || CADDY=/usr/bin/caddy
[ -f "$CF" ] || { echo "!! $CF not found — this kit expects the existing host Caddy from the Temp Mail setup. Aborting (Marzban itself is up on 127.0.0.1:8000)."; exit 1; }
[ -x "$CADDY" ] || { echo "!! caddy binary not found. Aborting before touching the Caddyfile."; exit 1; }
systemctl is-active --quiet caddy || { echo "!! systemd service 'caddy' is not active — unexpected on this box. Aborting before touching the Caddyfile."; exit 1; }

# Temp Mail gateway health BEFORE (the regression baseline)
MAILAPI_BEFORE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://mailapi.busterzone.mobi/health || true)
echo "   mailapi.busterzone.mobi/health before: ${MAILAPI_BEFORE:-no answer}"

CADDY_BAK=""
if grep -q "^${DOMAIN} {" "$CF"; then
  echo "OK: Caddy site for $DOMAIN already present — not appending twice."
else
  CADDY_BAK="$CF.bak.marzaws-$(date +%s)"
  cp "$CF" "$CADDY_BAK"
  echo "-- backup: $CADDY_BAK"
  {
    printf '\n'
    printf '# Marzban panel (added by setup-marzban-aws.sh)\n'
    printf '%s {\n' "$DOMAIN"
    printf '\treverse_proxy 127.0.0.1:8000\n'
    printf '}\n'
  } >> "$CF"
  echo "-- validating..."
  if ! "$CADDY" validate --adapter caddyfile --config "$CF" >/dev/null 2>&1; then
    echo "!! caddy validate FAILED — restoring backup, Caddy NOT reloaded."
    cp "$CADDY_BAK" "$CF"
    exit 1
  fi
  echo "OK: Caddyfile valid — reloading Caddy (existing sites keep serving)..."
  if ! systemctl reload caddy 2>/dev/null && ! systemctl restart caddy; then
    echo "!! Caddy reload/restart failed — restoring backup and restarting."
    cp "$CADDY_BAK" "$CF"
    systemctl restart caddy || true
    exit 1
  fi
  sleep 2
  systemctl is-active --quiet caddy || {
    echo "!! Caddy is not active after reload — restoring backup and restarting."
    cp "$CADDY_BAK" "$CF"
    systemctl restart caddy || true
    exit 1
  }
  # Regression gate: the Temp Mail gateway must be exactly as healthy as before.
  MAILAPI_AFTER=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://mailapi.busterzone.mobi/health || true)
  echo "   mailapi.busterzone.mobi/health after: ${MAILAPI_AFTER:-no answer}"
  if [ "$MAILAPI_BEFORE" = "200" ] && [ "$MAILAPI_AFTER" != "200" ]; then
    echo "!! Temp Mail gateway regressed after the Caddy change — restoring backup and reloading."
    cp "$CADDY_BAK" "$CF"
    systemctl reload caddy 2>/dev/null || systemctl restart caddy || true
    exit 1
  fi
  echo "OK: Caddy reloaded, Temp Mail gateway unaffected"
fi

echo "-- waiting for panel HTTPS (first cert can take ~1 min)..."
HTTPS=0
for i in $(seq 1 30); do
  sleep 4
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "https://$DOMAIN/dashboard/" || true)
  [ "$code" = "200" ] && { HTTPS=1; break; }
done
if [ "$HTTPS" != "1" ]; then
  echo "!! Panel HTTPS did not answer 200 at https://$DOMAIN/dashboard/ (yet)."
  echo "   Marzban itself is UP on 127.0.0.1:8000 and Caddy is valid — this is"
  echo "   usually the Let's Encrypt cert still issuing, or TCP 80/443 blocked"
  echo "   in the Lightsail firewall. Check: journalctl -u caddy -n 40"
  echo "   Login details: /root/marzban-login.txt"
  exit 1
fi
echo "OK: panel live at https://$DOMAIN/dashboard/"

# ---------- firewall (only touched if ufw is actually active) ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 8443/tcp >/dev/null 2>&1 || true
  ufw allow 1080/tcp >/dev/null 2>&1 || true
  ufw allow 1080/udp >/dev/null 2>&1 || true
  echo "OK: ufw rules added (80, 443, 8443, 1080 tcp + 1080 udp)"
fi

# ---------- final summary ----------
{
  echo "Marzban (AWS JP) — DONE"
  echo "  Panel : https://$DOMAIN/dashboard/  (login: /root/marzban-login.txt)"
  echo "  Server: $PUB_IP"
  echo "  VLESS : plain TCP $DOMAIN:8443   SS: $DOMAIN:1080 (tcp+udp)"
  echo "  Probe : user 'awsprobe' (5GB/day, 30 days) — links in /root/marzban-aws-links.txt"
  [ -n "$CADDY_BAK" ] && echo "  Caddy : site appended; backup at $CADDY_BAK"
  [ -f /root/marzban-aws-links.txt ] && { echo ""; echo "Probe links:"; cat /root/marzban-aws-links.txt; }
} > /root/marzban-aws.txt
chmod 600 /root/marzban-aws.txt
echo ""
echo "==========================================================="
cat /root/marzban-aws.txt
echo "==========================================================="
echo "=== END ==="
echo "Untouched neighbours: Caddy sites (mailapi), TUIC (UDP 443),"
echo "HY2 (UDP 8443), sales Xray (8388/8080/25574)."
echo "Provider firewall: TCP 80, 443, 8443, 1080 + UDP 1080 must be open."
echo "Next: run the bot kit (setup-tgbot-aws.sh), then test /start + claim."
