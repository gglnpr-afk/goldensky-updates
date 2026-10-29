#!/usr/bin/env bash
# gs-promo-guard.sh — GOLDENSKY kit: quota guard for the free promo
# Shadowsocks key (see add-ss-promo.sh). Installed to /usr/local/bin and
# run by cron every 5 minutes.
#
# How it works: Xray keeps per-user traffic counters in memory, keyed by
# the SS client's email ("promo300"). Each run polls the local Stats API
# with -reset (read + zero the counters) and adds the delta to a running
# total in /var/lib/gs-promo/state.txt, so the total survives Xray
# restarts (at most ~5 minutes of traffic can be missed across a restart
# that happens between two polls — acceptable for a free promo).
# When the total reaches the quota (default 300 GiB), the promo client is
# removed from the Xray config (backup + `xray -test` gate first), Xray
# is restarted, and the key stops working for everyone.
#
# Status file for the owner: /root/ss-promo-usage.txt
# Renew: re-run add-ss-promo.sh (new password, counter reset).
set -uo pipefail

CFG="${GS_CFG:-/usr/local/etc/xray/config.json}"
XRAY="${GS_XRAY:-/usr/local/bin/xray}"
API="${GS_API:-127.0.0.1:10085}"
EMAIL="${GS_PROMO_EMAIL:-promo300}"
TAG="${GS_PROMO_TAG:-ss-promo}"
QUOTA_BYTES="${GS_PROMO_QUOTA_BYTES:-322122547200}"   # 300 GiB
STATE_DIR="/var/lib/gs-promo"
STATE="$STATE_DIR/state.txt"
DISABLED="$STATE_DIR/disabled"
STATUS="/root/ss-promo-usage.txt"

mkdir -p "$STATE_DIR"
[ -f "$STATE" ] || echo 0 > "$STATE"
TOTAL="$(cat "$STATE" 2>/dev/null || echo 0)"
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac

# Poll one direction; prints the byte count or nothing on failure.
poll() {
  "$XRAY" api stats --server="$API" -name "user>>>$EMAIL>>>traffic>>>$1" -reset 2>/dev/null \
    | grep -o '"value":[ ]*[0-9]*' | grep -o '[0-9]*$' | head -1
}

if [ ! -f "$DISABLED" ]; then
  UP="$(poll uplink)"; DOWN="$(poll downlink)"
  # API unreachable (xray down?) — keep state, try again next run.
  if [ -n "$UP" ] || [ -n "$DOWN" ]; then
    TOTAL=$(( TOTAL + ${UP:-0} + ${DOWN:-0} ))
    echo "$TOTAL" > "$STATE"
  fi
fi

USED_GB="$(awk -v b="$TOTAL" 'BEGIN{printf "%.2f", b/1073741824}')"
QUOTA_GB="$(awk -v b="$QUOTA_BYTES" 'BEGIN{printf "%.0f", b/1073741824}')"
LEFT_GB="$(awk -v t="$TOTAL" -v q="$QUOTA_BYTES" 'BEGIN{d=(q-t)/1073741824; if(d<0)d=0; printf "%.2f", d}')"

if [ "$TOTAL" -ge "$QUOTA_BYTES" ] && [ ! -f "$DISABLED" ]; then
  cp "$CFG" "$CFG.bak.promo-$(date +%s)"
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
    echo "Promo quota reached — client disabled $(date -Is)" >> "$STATUS"
  else
    last="$(ls -t "$CFG".bak.promo-* 2>/dev/null | head -1)"
    [ -n "$last" ] && cp "$last" "$CFG"
    echo "WARNING: quota reached but config test failed — disable postponed" >> "$STATUS"
  fi
fi

STATE_TXT="ACTIVE"
[ -f "$DISABLED" ] && STATE_TXT="EXHAUSTED (key disabled)"
{
  echo "Free promo SS key — usage"
  echo "Used:      $USED_GB GB / $QUOTA_GB GB"
  echo "Remaining: $LEFT_GB GB"
  echo "State:     $STATE_TXT"
  echo "Updated:   $(date -Is)"
} > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
