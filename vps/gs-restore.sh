#!/usr/bin/env bash
# gs-restore.sh — GOLDENSKY kit: restore a gs-backup tarball onto a server.
#
# Typical use (dead/banned VPS replacement):
#   1. Buy a fresh VPS, install Xray (+ Caddy/gsmail if it was a mail box)
#      using the normal kit scripts — OR restore first and install after;
#      the config only takes effect once Xray is installed and restarted.
#   2. Upload the gs-backup-*.tar.gz to the new box, run this script.
#   3. Point the domain's Cloudflare A record at the NEW server IP.
#   4. Customer links keep working unchanged (same domain, same UUIDs).
#
# Safety: the CURRENT xray config is first copied to
# config.json.pre-restore-<timestamp>. The restored config must pass
# `xray -test` before xray is restarted; on failure the old config is
# put back and nothing is restarted.
# Only files present in the tarball are restored; missing ones are skipped.
#
# Usage:  sudo bash gs-restore.sh /root/gs-backup-<host>-<date>.tar.gz
set -uo pipefail

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
TB="${1:-}"
if [ -z "$TB" ] || [ ! -f "$TB" ]; then echo "Usage: sudo bash gs-restore.sh <gs-backup tarball>"; exit 1; fi

XRAY_CFG="${GS_XRAY_CFG:-/usr/local/etc/xray/config.json}"
XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"
DEST="${GS_DEST:-}"   # empty on a real server; test prefix only

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$TB" -C "$STAGE" || { echo "Cannot extract tarball."; exit 1; }

echo "=== Backup manifest ==="
cat "$STAGE/gs-backup-meta/manifest.txt" 2>/dev/null || echo "(no manifest)"
echo "======================="

put() { # put <path-relative-to-/> if present in the stage
  if [ -f "$STAGE/$1" ]; then
    mkdir -p "$DEST/$(dirname "$1")"
    cp "$STAGE/$1" "$DEST/$1"
    echo "  restored: /$1"
  fi
}

# 1) Pre-restore safety copy of the live config.
if [ -f "$DEST$XRAY_CFG" ]; then
  cp "$DEST$XRAY_CFG" "$DEST$XRAY_CFG.pre-restore-$(date +%Y%m%d-%H%M%S)"
  echo "Current config saved as $XRAY_CFG.pre-restore-*"
fi

# 2) Restore files.
put "${XRAY_CFG#/}"
for f in vmess-users.txt vless-users.txt; do put "root/$f"; done
for f in "$STAGE"/root/my-*.txt; do [ -f "$f" ] && put "root/$(basename "$f")"; done
put "etc/systemd/system/cloudflared-zt.service"
put "etc/caddy/Caddyfile"
put "var/lib/gsmail/gateway.db"

# 3) Validate the restored Xray config BEFORE restarting anything.
if [ -f "$DEST$XRAY_CFG" ] && [ -x "$XRAY_BIN" ] && [ -z "$DEST" ]; then
  if ! "$XRAY_BIN" -test -config "$XRAY_CFG" >/dev/null 2>&1; then
    echo "xray -test FAILED on the restored config — putting the old config back."
    last="$(ls -t "$XRAY_CFG".pre-restore-* 2>/dev/null | head -1)"
    [ -n "$last" ] && cp "$last" "$XRAY_CFG"
    exit 1
  fi
  echo "xray -test: OK"
fi

# 4) Reload/restart services that exist (real server only).
if [ -z "$DEST" ]; then
  systemctl daemon-reload 2>/dev/null || true
  systemctl list-unit-files xray.service >/dev/null 2>&1 && systemctl restart xray && echo "xray: $(systemctl is-active xray)"
  systemctl list-unit-files caddy.service >/dev/null 2>&1 && systemctl reload caddy 2>/dev/null && echo "caddy: reloaded"
  systemctl list-unit-files gsmail.service >/dev/null 2>&1 && systemctl restart gsmail && echo "gsmail: $(systemctl is-active gsmail)"
fi

echo
echo "=== RESTORE DONE ==="
echo "Next: point the domain's Cloudflare A record at THIS server's IP,"
echo "then test one customer link. If this box runs the Cloudflare Tunnel"
echo "(SG2-WS), start it with: systemctl enable --now cloudflared-zt"
