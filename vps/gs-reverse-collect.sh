#!/usr/bin/env bash
# gs-reverse-collect.sh — run on the FIRSTBYTE JP box (root@asia-premium,
# 132.243.30.145):  bash gs-reverse-collect.sh
#
# REVERSE of gs-migrate-send.sh (2026-11-09). Collects everything needed
# to rebuild this box's GOLDENSKY services on AWS JP Tokyo
# (52.194.182.108): the live Xray config (SS / VMess / VLESS incl. the
# SS promo :8390 inbound), TUIC (sing-box), the WireGuard shop (wg500),
# all add-*/gs-* helper scripts, guard crons and a full manifest —
# into ONE bundle:  /root/gs-reverse-bundle.tar.gz
#
# This script ONLY builds the bundle on this box. It does NOT scp
# anywhere and does NOT stop, restart or change any service. The AWS
# install script (gs-reverse-install.sh) pulls the bundle from there.
# Defensive by design: anything missing is skipped and written into
# MANIFEST.txt inside the bundle, never silently dropped.
set -uo pipefail

SRC_IP="132.243.30.145"
AWS_IP="52.194.182.108"
BUNDLE=/root/gs-reverse-bundle.tar.gz

[ "$(id -u)" = "0" ] || { echo "Run as root:  bash gs-reverse-collect.sh"; exit 1; }

HN="$(hostname)"
PUBIP="$(curl -s --max-time 6 ifconfig.me || echo unknown)"
echo "Box: hostname=$HN public_ip=$PUBIP"
if [ "$PUBIP" = "$AWS_IP" ]; then
  echo "ABORT: this is the AWS Tokyo box ($AWS_IP) — run this on FirstByte JP."
  exit 1
fi
if [ "$PUBIP" != "$SRC_IP" ] && [ "$PUBIP" != "unknown" ]; then
  echo "WARNING: public IP is $PUBIP, expected $SRC_IP (FirstByte JP)."
  echo "         Continuing anyway — check MANIFEST.txt on the AWS side."
fi

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
PAYLOAD="$STAGE/payload"
mkdir -p "$PAYLOAD/gs-meta"
LOG="$STAGE/collect.log"; : > "$LOG"

found()   { echo "FOUND   $1" | tee -a "$LOG" >/dev/null; echo "  + $1"; }
missing() { echo "MISSING $1" | tee -a "$LOG" >/dev/null; echo "  - $1 (missing, skipped)"; }

# grab <abs path> [required|expected] — copy preserving the full path
grab() {
  local p="$1" kind="${2:-}"
  if [ -f "$p" ]; then
    cp -a --parents "$p" "$PAYLOAD" && found "$p"
  elif [ "$kind" = "required" ] || [ "$kind" = "expected" ]; then
    missing "$p"
  fi
}
grab_dir() { # grab_dir <abs dir> [expected]
  local p="$1" kind="${2:-}"
  if [ -d "$p" ]; then
    cp -a --parents -r "$p" "$PAYLOAD" && found "$p/ (directory)"
  elif [ "$kind" = "expected" ]; then
    missing "$p/ (directory)"
  fi
}
grab_glob() { # grab_glob <pattern...> — silent when a glob matches nothing
  local p
  for p in "$@"; do
    [ -f "$p" ] && { cp -a --parents "$p" "$PAYLOAD" && found "$p"; }
  done
  return 0
}

echo "=== Collecting from FirstByte JP ($SRC_IP) ==="

############################ XRAY CONFIG ############################
# Find the LIVE xray config: canonical path first, then a fallback
# search for any config.json that actually parses and has inbounds.
XRAY_CFG=""
for cand in /usr/local/etc/xray/config.json /etc/xray/config.json \
            /usr/local/etc/xray/config/config.json; do
  if [ -f "$cand" ]; then XRAY_CFG="$cand"; break; fi
done
if [ -z "$XRAY_CFG" ]; then
  while IFS= read -r cand; do
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('inbounds') else 1)" "$cand" 2>/dev/null; then
      XRAY_CFG="$cand"; break
    fi
  done <<EOF
$(find /usr/local/etc /etc /opt -maxdepth 5 -name config.json -size -5M 2>/dev/null)
EOF
fi
if [ -n "$XRAY_CFG" ]; then
  echo "$XRAY_CFG" > "$PAYLOAD/gs-meta/xray-config-path.txt"
  grab "$XRAY_CFG" required
  # any sibling *.json (split configs etc.) from the same directory
  grab_glob "$(dirname "$XRAY_CFG")"/*.json
else
  missing "xray config.json (searched /usr/local/etc, /etc, /opt)"
fi
# xray binary itself is NOT collected — AWS already runs the same core.

############################ HELPER SCRIPTS + LINKS ############################
# Owner link/registry files in /root
grab_glob /root/my-*.txt
grab_glob /root/*-users.txt
grab_glob /root/add-*.sh /root/gs-*.sh /root/setup-*.sh
grab /root/ss-promo-usage.txt
grab /root/tuic-quota-status.txt
grab /root/wg-usage.txt
# Helper binaries/scripts in /usr/local/bin (gs / xray shop tooling)
grab_glob /usr/local/bin/add-* /usr/local/bin/del-* /usr/local/bin/gs-* \
          /usr/local/bin/list-* /usr/local/bin/remove-* \
          /usr/local/bin/tuic-render.py
# SS promo + quota guards explicitly (also matched by the gs-* glob)
grab /usr/local/bin/gs-promo-guard.sh expected
grab /usr/local/bin/gs-quota-guard.sh

############################ TUIC (sing-box) ############################
grab /usr/local/etc/sing-box/config.json expected
grab /usr/local/etc/sing-box/cert.pem expected
grab /usr/local/etc/sing-box/key.pem expected
grab_dir /usr/local/etc/sing-box
grab /etc/systemd/system/gs-tuic.service expected
grab /usr/local/bin/sing-box expected
grab /usr/local/bin/gs-stats-query
grab /usr/local/bin/add-tuic expected
grab /usr/local/bin/gs-tuic-guard expected
grab /usr/local/bin/gs-tuic-guard.sh
grab /root/tuic-users.txt expected
grab /root/tuic-domain.txt
grab_dir /var/lib/gs-tuic

############################ WIREGUARD SHOP (wg500) ############################
grab /etc/wireguard/wg500.conf expected
grab /etc/wireguard/clients.db
grab /etc/wireguard/host.txt
grab /etc/sysctl.d/99-wg500.conf
grab_dir /root/wg-keys expected
grab_dir /var/lib/gs-wg
grab /usr/local/bin/add-wg expected
grab /usr/local/bin/del-wg
grab /usr/local/bin/gs-wg-guard.sh expected

############################ HYSTERIA2 (reference only) ############################
# AWS already runs the ORIGINAL HY2 with identical credentials, so the
# install script will NOT overwrite it. Collected as a fallback record.
grab /etc/hysteria/config.yaml
grab /etc/systemd/system/gs-hy2-main.service
if [ -d /etc/letsencrypt/live/busterzone.mobi ]; then
  mkdir -p "$PAYLOAD/gs-meta/cert-busterzone"
  for f in cert.pem chain.pem fullchain.pem privkey.pem; do
    if [ -e "/etc/letsencrypt/live/busterzone.mobi/$f" ]; then
      cp -aL "/etc/letsencrypt/live/busterzone.mobi/$f" "$PAYLOAD/gs-meta/cert-busterzone/$f"
      found "letsencrypt/busterzone.mobi/$f (dereferenced)"
    fi
  done
fi

############################ SYSTEMD UNITS + CRON ############################
grab_glob /etc/systemd/system/gs-*.service /etc/systemd/system/sing-box*.service \
          /etc/systemd/system/xray.service
grab_glob /etc/cron.d/gs-* /etc/cron.d/*tuic* /etc/cron.d/*wg* /etc/cron.d/*promo*
crontab -l > "$PAYLOAD/gs-meta/root-crontab.txt" 2>/dev/null \
  && found "root crontab (dumped to gs-meta/root-crontab.txt)" \
  || echo "(no root crontab)" > "$PAYLOAD/gs-meta/root-crontab.txt"
[ -f /etc/crontab ] && cp -a /etc/crontab "$PAYLOAD/gs-meta/etc-crontab.txt"

############################ MANIFEST ############################
SS_OUT="$PAYLOAD/gs-meta/listening-ss.txt"
ss -tulnp > "$SS_OUT" 2>/dev/null || netstat -tulnp > "$SS_OUT" 2>/dev/null || true
{
  echo "=== GS REVERSE bundle manifest (FirstByte JP -> AWS JP) ==="
  echo "hostname: $HN"
  echo "public_ip: $PUBIP"
  echo "expected_source_ip: $SRC_IP"
  echo "target_ip: $AWS_IP"
  echo "date: $(date -Is)"
  echo "os: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
  echo "xray_config_path: ${XRAY_CFG:-NOT FOUND}"
  echo "xray: $(/usr/local/bin/xray -version 2>/dev/null | head -1 || echo unknown)"
  echo "sing-box: $(/usr/local/bin/sing-box version 2>/dev/null | head -1 || echo unknown)"
  echo "wireguard: $(wg --version 2>/dev/null || echo unknown)"
  echo "tuic_cert_enddate: $(openssl x509 -enddate -noout -in /usr/local/etc/sing-box/cert.pem 2>/dev/null || echo unknown)"
  echo "tuic_cert_san: $(openssl x509 -ext subjectAltName -noout -in /usr/local/etc/sing-box/cert.pem 2>/dev/null | tail -1 || echo unknown)"
  echo
  echo "--- service states (source box) ---"
  for svc in xray gs-tuic wg-quick@wg500 gs-hy2-main hysteria; do
    echo "$svc: $(systemctl is-active "$svc" 2>/dev/null || echo n/a)"
  done
  echo
  echo "--- wg show wg500 (public keys + counters only) ---"
  wg show wg500 2>/dev/null | grep -E "interface:|peer:|endpoint:|transfer:" || echo "(wg500 not up)"
  echo
  echo "--- listening ports: see gs-meta/listening-ss.txt ---"
  echo
  echo "--- collected / missing ---"
  cat "$LOG"
  echo
  echo "--- file inventory (path, bytes) ---"
  ( cd "$PAYLOAD" && find . -type f -printf "%p %s\n" | sort )
} > "$PAYLOAD/MANIFEST.txt"
cat "$PAYLOAD/MANIFEST.txt"

# Abort only if there is literally nothing worth migrating.
if [ -z "$XRAY_CFG" ] && [ ! -f "$PAYLOAD/usr/local/etc/sing-box/config.json" ] \
   && [ ! -f "$PAYLOAD/etc/wireguard/wg500.conf" ]; then
  echo "ABORT: no Xray config, no TUIC config and no wg500.conf found — nothing to migrate."
  exit 1
fi

tar -czf "$BUNDLE" -C "$STAGE" payload
chmod 600 "$BUNDLE"
echo
echo "=== BUNDLE READY (stays on THIS box — nothing was sent) ==="
echo "Bundle: $BUNDLE ($(du -h "$BUNDLE" | cut -f1), sha256 $(sha256sum "$BUNDLE" | cut -c1-16)...)"
echo "Check the MISSING lines above: anything expected-but-missing is"
echo "NOT in the bundle and must be told to Muse before installing."
echo
echo "Next step: on the AWS JP terminal (ubuntu) run gs-reverse-install.sh"
echo "— it will scp-pull this bundle (you type this box's root password"
echo "in the AWS terminal) and merge-install everything there."
