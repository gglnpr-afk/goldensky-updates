#!/usr/bin/env bash
# gs-backup.sh — GOLDENSKY kit: snapshot EVERYTHING needed to rebuild this
# server on a fresh VPS with all customer keys intact:
#   - Xray config (every inbound + every per-user UUID lives in it)
#   - per-user key lists (/root/vmess-users.txt, /root/vless-users.txt)
#   - server note files (/root/my-*.txt — links, passwords)
#   - Cloudflare tunnel unit (cloudflared-zt.service, if present)
#   - Caddyfile (if present)
#   - Temp Mail gateway DB (/var/lib/gsmail/gateway.db, if present —
#     customer addresses + recovery hashes; mailpit mail itself is NOT
#     backed up on purpose: temp mail is transient, the DB is the state)
#
# Output: /root/backups/gs-backup-<hostname>-<YYYYMMDD-HHMM>.tar.gz (0600)
# Keeps the newest 8 backups, deletes older ones.
#
# *** THIS FILE CONTAINS ALL CUSTOMER KEYS *** — treat it like a password.
# Keep one copy OFF the server (download it to your phone via Termius SFTP
# download). A backup that lives only on the dead VPS is not a backup.
#
# Restore with: gs-restore.sh <this-file>
# Run it: after adding new customers, and at least weekly.
#
# Usage:  sudo bash gs-backup.sh
set -uo pipefail

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi

XRAY_CFG="${GS_XRAY_CFG:-/usr/local/etc/xray/config.json}"
ROOTDIR="${GS_ROOTDIR:-/root}"
CF_UNIT="${GS_CF_UNIT:-/etc/systemd/system/cloudflared-zt.service}"
CADDYFILE="${GS_CADDYFILE:-/etc/caddy/Caddyfile}"
GSMAIL_DB="${GS_GSMAIL_DB:-/var/lib/gsmail/gateway.db}"
OUTDIR="${GS_OUTDIR:-/root/backups}"

mkdir -p "$OUTDIR" && chmod 700 "$OUTDIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
LIST="$STAGE/files.txt"; : > "$LIST"

add() { # add <absolute path> if it exists
  if [ -f "$1" ]; then echo "${1#/}" >> "$LIST"; else echo "  skip (not found): $1"; fi
}

echo "Collecting files..."
add "$XRAY_CFG"
add "$ROOTDIR/vmess-users.txt"
add "$ROOTDIR/vless-users.txt"
for f in "$ROOTDIR"/my-*.txt; do [ -f "$f" ] && add "$f"; done
add "$CF_UNIT"
add "$CADDYFILE"
add "$GSMAIL_DB"

if [ ! -s "$LIST" ]; then echo "Nothing to back up — no known files found."; exit 1; fi
if ! grep -qx "${XRAY_CFG#/}" "$LIST"; then
  echo "WARNING: Xray config NOT included ($XRAY_CFG missing) — backup has no server keys!"
fi

# Manifest: what/where/when this backup came from.
MANIFEST="$STAGE/manifest.txt"
{
  echo "hostname: $(hostname)"
  echo "date: $(date -Is)"
  echo "public_ip: $(curl -s --max-time 5 ifconfig.me || echo unknown)"
  echo "xray: $( (command -v xray >/dev/null && xray -version 2>/dev/null | head -1) || echo unknown)"
  echo "files:"
  while read -r p; do echo "  /$p  (sha256: $(sha256sum "/$p" | cut -d' ' -f1))"; done < "$LIST"
} > "$MANIFEST"
mkdir -p "$STAGE/gs-backup-meta"
cp "$MANIFEST" "$STAGE/gs-backup-meta/manifest.txt"

NAME="gs-backup-$(hostname)-$(date +%Y%m%d-%H%M).tar.gz"
tar -czf "$OUTDIR/$NAME" -C "$STAGE" gs-backup-meta/manifest.txt -C / -T "$LIST"
chmod 600 "$OUTDIR/$NAME"

# Retention: keep newest 8.
ls -t "$OUTDIR"/gs-backup-*.tar.gz 2>/dev/null | tail -n +9 | while read -r old; do rm -f "$old"; done

echo
echo "=== BACKUP DONE ==="
echo "File:   $OUTDIR/$NAME"
echo "Size:   $(du -h "$OUTDIR/$NAME" | cut -f1)"
echo "SHA256: $(sha256sum "$OUTDIR/$NAME" | cut -d' ' -f1)"
echo
echo "NOW: download this file to your phone (Termius: SFTP -> download)"
echo "and keep it somewhere safe. It contains ALL customer keys."
