#!/bin/bash
# GOLDENSKY — free port 443 on the FirstByte box for Temp Mail HTTPS.
# Removes ONLY the Xray inbound that listens on :443 (the unused
# VLESS+REALITY inbound). Every other inbound (Shadowsocks :8388,
# VLESS-WS for the Cloudflare tunnel, ...) is left untouched.
# Safety: timestamped backup first; the new config must pass
# `xray -test` or the backup is restored and xray is NOT restarted.
# Usage: sudo bash free-443.sh [config-path]
set -e
CFG="${1:-/usr/local/etc/xray/config.json}"
[ "$(id -u)" != "0" ] && { echo "Run with sudo"; exit 1; }
[ -f "$CFG" ] || { echo "Config not found: $CFG"; exit 1; }
XRAY=/usr/local/bin/xray; [ -x "$XRAY" ] || XRAY=xray
BAK="$CFG.bak.$(date +%s)"
cp "$CFG" "$BAK"
echo "backup: $BAK"
python3 - "$CFG" <<'PYEOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
before = cfg.get("inbounds", [])
keep = [ib for ib in before if ib.get("port") != 443]
removed = len(before) - len(keep)
for ib in before:
    print(f"  inbound: port={ib.get('port')} protocol={ib.get('protocol')}")
if removed == 0:
    print("No :443 inbound found — nothing to do.")
    sys.exit(0)
cfg["inbounds"] = keep
json.dump(cfg, open(p, "w"), indent=2)
print(f"Removed {removed} inbound(s) on :443; {len(keep)} inbound(s) kept.")
PYEOF
if ! "$XRAY" -test -config "$CFG" >/dev/null 2>&1; then
  echo "xray -test FAILED — restoring backup, xray NOT restarted"
  cp "$BAK" "$CFG"
  exit 1
fi
echo "xray -test OK"
systemctl restart xray
sleep 1
systemctl is-active --quiet xray && echo "xray: running" || { echo "xray NOT running — check: journalctl -u xray -n 20"; exit 1; }
echo
echo "== Ports now =="
ss -tlnp | grep -E ':25 |:80 |:443 |:8388 ' || true
echo "DONE — :443 should be gone from the list, :8388 (Shadowsocks) still there."
