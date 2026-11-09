#!/usr/bin/env bash
# gs-migrate-send.sh — run on the AWS TOKYO box (sudo bash gs-migrate-send.sh).
# Collects everything needed to rebuild this box's customer services
# (Xray SS/VMess/VLESS + Hysteria2 + cert) into ONE bundle and pushes it
# straight to the FirstByte JP box (132.243.30.145) with scp.
# You will be asked for the FirstByte box's root password ONCE (typed in
# this terminal only — it never goes anywhere else).
# The bundle also stays in /home/ubuntu as a fallback.
set -uo pipefail

DEST_IP="132.243.30.145"
[ "$(id -u)" = "0" ] || { echo "Run as root:  sudo bash gs-migrate-send.sh"; exit 1; }

echo "=== GS migrate: collect from $(hostname) ==="
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/payload"

need() { # required file
  if [ -f "$1" ]; then cp -a "$1" "$STAGE/payload/$(echo "$1" | tr / _)"; echo "  + $1";
  else echo "  !! MISSING (required): $1"; MISSING=1; fi
}
opt() { if [ -f "$1" ]; then cp -a "$1" "$STAGE/payload/$(echo "$1" | tr / _)"; echo "  + $1"; fi; }

MISSING=0
need /usr/local/etc/xray/config.json
need /etc/hysteria/config.yaml
opt /root/hysteria-link.txt
for f in /root/my-*.txt; do [ -f "$f" ] && opt "$f"; done
opt /root/vmess-users.txt
opt /root/vless-users.txt

# Cert: copy the live dir DEREFFed (real PEM files, not symlinks)
CERTDIR=/etc/letsencrypt/live/busterzone.mobi
if [ -d "$CERTDIR" ]; then
  mkdir -p "$STAGE/payload/cert"
  for f in cert.pem chain.pem fullchain.pem privkey.pem; do
    if [ -e "$CERTDIR/$f" ]; then cp -aL "$CERTDIR/$f" "$STAGE/payload/cert/$f"; echo "  + cert/$f"; fi
  done
else
  echo "  !! MISSING (required): $CERTDIR"; MISSING=1
fi

# Manifest
{
  echo "hostname: $(hostname)"
  echo "public_ip: $(curl -s --max-time 5 ifconfig.me || echo unknown)"
  echo "date: $(date -Is)"
  echo "xray: $(/usr/local/bin/xray -version 2>/dev/null | head -1)"
  echo "hysteria: $(/usr/local/bin/hysteria version 2>/dev/null | grep -i version | head -1)"
  echo "cert_enddate: $(openssl x509 -enddate -noout -in "$STAGE/payload/cert/fullchain.pem" 2>/dev/null || echo unknown)"
} > "$STAGE/payload/manifest.txt"
cat "$STAGE/payload/manifest.txt"

[ "$MISSING" = "1" ] && { echo "ABORT: required files missing — nothing sent."; exit 1; }

BUNDLE=/home/ubuntu/gs-migrate-bundle.tar.gz
tar -czf "$BUNDLE" -C "$STAGE" payload
chmod 600 "$BUNDLE"; chown ubuntu: "$BUNDLE" 2>/dev/null || true
echo
echo "Bundle: $BUNDLE ($(du -h "$BUNDLE" | cut -f1), sha256 $(sha256sum "$BUNDLE" | cut -c1-16)...)"

echo
echo "=== Sending to FirstByte JP ($DEST_IP) — type its ROOT password when asked ==="
if scp -o StrictHostKeyChecking=accept-new "$BUNDLE" "root@$DEST_IP:/root/gs-migrate-bundle.tar.gz"; then
  echo
  echo "=== SENT OK ==="
  echo "Now go to the FirstByte JP terminal (root@asia-premium) and run the install command."
else
  echo
  echo "!! scp failed (wrong password or unreachable). The bundle is safe at:"
  echo "   $BUNDLE"
  echo "Tell Muse and we will use the fallback."
  exit 1
fi
