#!/bin/bash
# fix-caddy-h3-off.sh — free UDP 443 on the FirstByte SG box for the WG-443 test.
#
# Caddy holds UDP *:443 for HTTP/3 (QUIC). The Temp Mail app talks to the
# gateway over plain HTTPS/TCP (its HTTP stack has no QUIC), so HTTP/3 is
# unused. This script turns HTTP/3 off in Caddy's global options
# (protocols h1 h2), which releases the UDP 443 listener while every site
# keeps serving normally over TCP.
#
# Safety: timestamped Caddyfile backup; the new config must pass
# `caddy validate` BEFORE any restart; if Caddy fails to come back or the
# mailapi health check fails, the backup is restored automatically.
#
# Undo:  cp /etc/caddy/Caddyfile.bak.h3off-* /etc/caddy/Caddyfile && systemctl restart caddy
set -e

CF=/etc/caddy/Caddyfile
CADDY=$(command -v caddy || true)
[ -n "$CADDY" ] || CADDY=/usr/local/bin/caddy

echo "=== Caddy HTTP/3 off (free UDP 443) ==="
[ "$(id -u)" = "0" ] || { echo "!! Run as root. Aborting."; exit 1; }
[ -f "$CF" ] || { echo "!! $CF not found. Aborting."; exit 1; }
[ -x "$CADDY" ] || { echo "!! caddy binary not found. Aborting."; exit 1; }

if grep -q "protocols h1 h2" "$CF"; then
  echo "-- HTTP/3 already off in Caddyfile."
else
  BAK="$CF.bak.h3off-$(date +%s)"
  cp "$CF" "$BAK"
  echo "-- backup: $BAK"
  python3 - "$CF" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
if "protocols" in text:
    print("-- a protocols setting already exists; leaving file unchanged")
    sys.exit(0)
lines = text.split("\n")
block = ["\tservers {", "\t\tprotocols h1 h2", "\t}"]
# find first meaningful line
i = 0
while i < len(lines) and (lines[i].strip() == "" or lines[i].strip().startswith("#")):
    i += 1
if i < len(lines) and lines[i].strip() == "{":
    # existing global options block: insert just after its opening brace
    lines[i + 1:i + 1] = block
    print("-- inserted into existing global block")
else:
    lines = ["{"] + block + ["}", ""] + lines
    print("-- prepended a new global block")
open(path, "w").write("\n".join(lines))
PYEOF
  echo "-- validating..."
  if ! "$CADDY" validate --adapter caddyfile --config "$CF" >/dev/null 2>&1; then
    echo "!! caddy validate FAILED — restoring backup, nothing restarted."
    cp "$BAK" "$CF"
    exit 1
  fi
  echo "-- config valid"
fi

echo "-- restarting caddy..."
if ! systemctl restart caddy; then
  echo "!! caddy restart failed — restoring backup."
  cp "$CF.bak.h3off-"* "$CF" 2>/dev/null || true
  systemctl restart caddy || true
  exit 1
fi
sleep 1
systemctl is-active caddy

echo "-- UDP 443 listeners now:"
if ss -lun | grep -q ":443 "; then
  ss -lunp | grep ":443 " || true
  echo "!! UDP 443 still bound — WG kit will keep aborting; report this output."
  exit 1
else
  echo "   (none — UDP 443 is FREE)"
fi

echo "-- mailapi health:"
curl -s --max-time 15 -o /dev/null -w "   https://mailapi.luciferdead.com/health -> %{http_code}\n" \
  https://mailapi.luciferdead.com/health || echo "   (health check curl failed — report this)"

echo ""
echo "DONE. Next: re-run the WG-443 kit:"
echo "  curl -sL https://is.gd/FBLExB -o wg443.sh && sudo bash wg443.sh"
