#!/usr/bin/env bash
# gs-free-guard.sh — GOLDENSKY kit: quota guard for the free VLESS+WS+TLS
# key (see setup-free-vless.sh). Installed to /usr/local/bin and run by
# cron every 5 minutes.
#
# How it works: all free-key traffic passes through the gs-meter relay,
# which keeps a cumulative byte total in /var/lib/gs-free/bytes.txt
# (uplink + downlink, WebSocket framing included — a small, acceptable
# overhead, same as the SSH free pool's bridge counter). This guard just
# reads that total. (Metering lives in the relay so the quota never
# depends on Xray's internal traffic counters.)
# When the total reaches the quota (default 300 GiB), the free client
# is removed from the vless-free inbound (backup + `xray -test` gate
# first), Xray is restarted, and the key stops working for everyone.
#
# Status file for the owner: /root/vless-free-usage.txt
# Renew: re-run setup-free-vless.sh (new UUID, counter reset).
set -uo pipefail

CFG="${GS_CFG:-/usr/local/etc/xray/config.json}"
XRAY="${GS_XRAY:-/usr/local/bin/xray}"
TAG="${GS_FREE_TAG:-vless-free}"
EMAIL="${GS_FREE_EMAIL:-free300}"
QUOTA_BYTES="${GS_FREE_QUOTA_BYTES:-322122547200}"   # 300 GiB
STATE_DIR="${GS_FREE_STATE_DIR:-/var/lib/gs-free}"
BYTES_FILE="$STATE_DIR/bytes.txt"
DISABLED="$STATE_DIR/disabled"
STATUS="${GS_FREE_STATUS:-/root/vless-free-usage.txt}"

mkdir -p "$STATE_DIR"
TOTAL="$(cat "$BYTES_FILE" 2>/dev/null || echo 0)"
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac

USED_GB="$(awk -v b="$TOTAL" 'BEGIN{printf "%.2f", b/1073741824}')"
QUOTA_GB="$(awk -v b="$QUOTA_BYTES" 'BEGIN{printf "%.0f", b/1073741824}')"
LEFT_GB="$(awk -v t="$TOTAL" -v q="$QUOTA_BYTES" 'BEGIN{d=(q-t)/1073741824; if(d<0)d=0; printf "%.2f", d}')"

if [ "$TOTAL" -ge "$QUOTA_BYTES" ] && [ ! -f "$DISABLED" ]; then
  cp "$CFG" "$CFG.bak.free-$(date +%s)"
  EMAIL="$EMAIL" TAG="$TAG" CFG="$CFG" python3 - <<'PYEOF'
import json, os
cfg = json.load(open(os.environ["CFG"]))
tag, email = os.environ["TAG"], os.environ["EMAIL"]
for ib in cfg.get("inbounds", []):
    if ib.get("tag") == tag:
        st = ib.get("settings", {})
        st["clients"] = [c for c in st.get("clients", []) if c.get("email") != email]
json.dump(cfg, open(os.environ["CFG"], "w"), indent=2)
PYEOF
  if "$XRAY" -test -config "$CFG" >/dev/null 2>&1; then
    systemctl restart xray
    touch "$DISABLED"
    echo "Free quota reached — client disabled $(date -Is)" >> "$STATUS"
  else
    last="$(ls -t "$CFG".bak.free-* 2>/dev/null | head -1)"
    [ -n "$last" ] && cp "$last" "$CFG"
    echo "WARNING: quota reached but config test failed — disable postponed" >> "$STATUS"
  fi
fi

STATE_TXT="ACTIVE"
[ -f "$DISABLED" ] && STATE_TXT="EXHAUSTED (key disabled)"
{
  echo "Free VLESS key (300GB pool) — usage"
  echo "Used:      $USED_GB GB / $QUOTA_GB GB"
  echo "Remaining: $LEFT_GB GB"
  echo "State:     $STATE_TXT"
  echo "Updated:   $(date -Is)"
} > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
