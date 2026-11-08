#!/bin/bash
# ============================================================
# fix-hy2-plain-8443.sh — move gs-hy2-plain from UDP 9443 to
# UDP 8443 on the Marzban box, and free UDP 8443 first.
# Marker: fix-hy2-plain v1
#
# Why: the PLAIN HY2 leg on UDP 9443 never logged a single
# client connection (install day onward) while STRONG on
# UDP 443 works from the same phone/carrier — the 9443 leg
# does not complete on this path. UDP 8443 is the port where
# this user's GOLDENSKY-HY2 worked before, but on THIS box
# Caddy holds UDP 8443 for the panel's HTTP/3.
#
# What it does:
#   1. Turns OFF HTTP/3 in the panel's Caddy (adds
#      "servers { protocols h1 h2 }" to the Caddyfile global
#      options). Panel + subscriptions keep working over
#      TCP HTTPS (browsers/apps do not need H3 here).
#      Gate: `caddy validate` inside the gs-caddy container
#      BEFORE restart; timestamped backup; auto-restore if
#      the panel does not answer HTTPS 200 afterwards.
#   2. Moves gs-hy2-plain's listen port 9443 -> 8443.
#      The PLAIN password does NOT change; STRONG (UDP 443,
#      obfs + hopping) is not touched at all.
#   3. Rewrites the PLAIN line in /root/my-hy2-dpi.txt and
#      prints the new link (same password, port 8443).
#
# Undo: cp /etc/caddy/Caddyfile.bak.plain8443-* /etc/caddy/Caddyfile
#       docker restart gs-caddy
#       sed -i 's/^listen: .*/listen: :9443/' /etc/hysteria-dpi/plain.yaml
#       systemctl restart gs-hy2-plain
# ============================================================
set -e

DOMAIN=marz.gloriafreeproton.io
OLD_PORT=9443
NEW_PORT=8443
CF=/etc/caddy/Caddyfile
PLAIN_YAML=/etc/hysteria-dpi/plain.yaml
LINKS_FILE=/root/my-hy2-dpi.txt

echo "=== Fix PLAIN: UDP $OLD_PORT -> $NEW_PORT (Caddy HTTP/3 off) ==="
[ "$(id -u)" = "0" ] || { echo "Run as root:  sudo bash fix-hy2-plain-8443.sh"; exit 1; }
[ -f "$PLAIN_YAML" ] || { echo "!! $PLAIN_YAML not found — the DPI kit is not installed. Aborting."; exit 1; }
[ -f "$CF" ] || { echo "!! $CF not found. Aborting."; exit 1; }
grep -q "$DOMAIN" "$CF" || { echo "!! $CF does not mention $DOMAIN — unexpected Caddyfile. Aborting."; exit 1; }
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "gs-caddy" || { echo "!! gs-caddy container is not running. Aborting."; exit 1; }
systemctl is-active --quiet gs-hy2-plain || { echo "!! gs-hy2-plain is not active. Aborting (check it first)." ; exit 1; }

PASS_PLAIN=$(awk '/^  password:/{print $2}' "$PLAIN_YAML")
[ -n "$PASS_PLAIN" ] || { echo "!! Could not read the PLAIN password from $PLAIN_YAML. Aborting."; exit 1; }
CUR_PORT=$(grep '^listen:' "$PLAIN_YAML" | tr -dc '0-9')
echo "-- current PLAIN port: ${CUR_PORT:-unknown}; password kept unchanged"
if [ "$CUR_PORT" = "$NEW_PORT" ]; then
  echo "   PLAIN already listens on $NEW_PORT — nothing to move."
  exit 0
fi

# ---------- 1. Caddy: HTTP/3 off (validate-gated, auto-rollback) ----------
BAK="$CF.bak.plain8443-$(date +%s)"
cp "$CF" "$BAK"
echo "-- Caddyfile backup: $BAK"
if grep -q "protocols h1 h2" "$CF"; then
  echo "-- HTTP/3 already off in Caddyfile; skipping the edit."
else
  python3 - "$CF" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
if "protocols" in text:
    print("-- a protocols setting already exists; leaving the file unchanged")
    sys.exit(0)
lines = text.split("\n")
block = ["\tservers {", "\t\tprotocols h1 h2", "\t}"]
i = 0
while i < len(lines) and (lines[i].strip() == "" or lines[i].strip().startswith("#")):
    i += 1
if i < len(lines) and lines[i].strip() == "{":
    lines[i + 1:i + 1] = block
    print("-- inserted into the existing global block")
else:
    lines = ["{"] + block + ["}", ""] + lines
    print("-- prepended a new global block")
open(path, "w").write("\n".join(lines))
PYEOF
fi
echo "-- validating the new Caddyfile inside gs-caddy..."
if ! docker exec gs-caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  echo "!! caddy validate FAILED — restoring the backup; nothing was restarted."
  cp "$BAK" "$CF"
  exit 1
fi
echo "-- config valid; restarting gs-caddy..."
docker restart gs-caddy >/dev/null
PANEL=0
for i in $(seq 1 30); do
  sleep 4
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "https://$DOMAIN:8443/dashboard/" || true)
  [ "$code" = "200" ] && { PANEL=1; break; }
done
if [ "$PANEL" != "1" ]; then
  echo "!! Panel did not answer HTTPS 200 after the Caddy change — restoring the backup."
  cp "$BAK" "$CF"
  docker restart gs-caddy >/dev/null || true
  exit 1
fi
echo "OK: panel HTTPS still live (HTTP/3 off)"

# ---------- 2. UDP 8443 must now be free ----------
sleep 1
if ss -lun | grep -q ":${NEW_PORT}[[:space:]]"; then
  echo "!! UDP $NEW_PORT is STILL bound after HTTP/3 off:"
  ss -lunp | grep ":${NEW_PORT}[[:space:]]" || true
  echo "   Restoring the Caddyfile backup to leave the box as it was."
  cp "$BAK" "$CF"
  docker restart gs-caddy >/dev/null || true
  exit 1
fi
echo "OK: UDP $NEW_PORT is free"

# ---------- 3. Move PLAIN to 8443 ----------
sed -i "s/^listen: .*/listen: :$NEW_PORT/" "$PLAIN_YAML"
systemctl restart gs-hy2-plain
UP=0
for i in $(seq 1 15); do
  sleep 2
  if systemctl is-active --quiet gs-hy2-plain && ss -lun | grep -q ":${NEW_PORT}[[:space:]]"; then UP=1; break; fi
done
if [ "$UP" != "1" ]; then
  echo "!! gs-hy2-plain did not come up on $NEW_PORT — rolling everything back."
  sed -i "s/^listen: .*/listen: :$OLD_PORT/" "$PLAIN_YAML"
  systemctl restart gs-hy2-plain || true
  cp "$BAK" "$CF"
  docker restart gs-caddy >/dev/null || true
  journalctl -u gs-hy2-plain --no-pager -n 15 || true
  exit 1
fi
echo "OK: gs-hy2-plain listening on UDP $NEW_PORT"

# ---------- 4. Firewall ----------
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=${NEW_PORT}/udp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow ${NEW_PORT}/udp >/dev/null 2>&1 || true
fi

# ---------- 5. New link (same password) ----------
LINK_PLAIN="hy2://${PASS_PLAIN}@${DOMAIN}:${NEW_PORT}?security=tls&sni=${DOMAIN}#HY2-DPI-PLAIN"
if [ -f "$LINKS_FILE" ]; then
  STRONG_LINE=$(grep "obfs=" "$LINKS_FILE" | head -1 || true)
  {
    echo "# HY2 DPI pair — Marzban box $DOMAIN (PLAIN moved to $NEW_PORT by fix-hy2-plain-8443.sh)"
    echo "# STRONG (Aeriva / v2rayNG / GOLDENSKY 1.0.37+):"
    [ -n "$STRONG_LINE" ] && echo "$STRONG_LINE"
    echo "# PLAIN (GOLDENSKY + Aeriva + v2rayNG):"
    echo "$LINK_PLAIN"
  } > "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
fi

echo ""
echo "==========================================================="
echo "DONE: PLAIN is now on UDP $NEW_PORT (password unchanged)"
echo ""
echo "New PLAIN link:"
echo "$LINK_PLAIN"
echo ""
echo "  Re-import this link in GOLDENSKY (delete the old PLAIN"
echo "  profile first — its port was $OLD_PORT), connect, and"
echo "  check: My IP must show 83.147.235.168"
echo "  STRONG link: unchanged, no need to touch it."
echo "  Panel: https://$DOMAIN:8443/dashboard/ still live (TCP)."
echo "==========================================================="
