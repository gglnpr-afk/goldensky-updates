#!/usr/bin/env bash
# gs-quota-guard.sh — GOLDENSKY kit: per-customer quota guard for the
# SS shop inbound (see add-ss-quota.sh). Installed to /usr/local/bin,
# run by cron every 5 minutes.
#
# Registry: /root/quota-users.txt — one line per customer:
#   name <TAB> email <TAB> quotaBytes <TAB> expiryEpoch <TAB> password
# For each ACTIVE customer it polls the Xray Stats API (with -reset) and
# accumulates up+down bytes in /var/lib/gs-quota/<email>.bytes, so totals
# survive Xray restarts (up to ~5 min of traffic can be missed across a
# restart between polls). A customer is DISABLED — client removed from
# the inbound — when EITHER the quota is used up OR the expiry passes.
# All disables in one run are batched into a single config edit +
# `xray -test` + restart (backup first, restore on failure).
#
# Owner status anytime: cat /root/quota-status.txt
set -uo pipefail

CFG="${GS_CFG:-/usr/local/etc/xray/config.json}"
XRAY="${GS_XRAY:-/usr/local/bin/xray}"
API="${GS_API:-127.0.0.1:10085}"
TAG="${GS_SHOP_TAG:-ss-shop}"
REG="/root/quota-users.txt"
STATE_DIR="/var/lib/gs-quota"
STATUS="/root/quota-status.txt"

mkdir -p "$STATE_DIR"
[ -f "$REG" ] || exit 0

poll() { # $1=email $2=uplink|downlink -> bytes or empty
  "$XRAY" api stats --server="$API" -name "user>>>$1>>>traffic>>>$2" -reset 2>/dev/null \
    | grep -o '"value":[ ]*[0-9]*' | grep -o '[0-9]*$' | head -1
}

NOW="$(date +%s)"
DISABLE_LIST=""
STATUS_TMP="$(mktemp)"

while IFS=$'\t' read -r NAME EMAIL QUOTA EXPIRY PASS; do
  [ -n "${EMAIL:-}" ] || continue
  SF="$STATE_DIR/$EMAIL.bytes"
  DF="$STATE_DIR/$EMAIL.disabled"
  TOTAL="$(cat "$SF" 2>/dev/null || echo 0)"
  case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac

  if [ ! -f "$DF" ]; then
    UP="$(poll "$EMAIL" uplink)"; DOWN="$(poll "$EMAIL" downlink)"
    if [ -n "$UP" ] || [ -n "$DOWN" ]; then
      TOTAL=$(( TOTAL + ${UP:-0} + ${DOWN:-0} ))
      echo "$TOTAL" > "$SF"
    fi
    if [ "$TOTAL" -ge "$QUOTA" ] || [ "$NOW" -ge "$EXPIRY" ]; then
      DISABLE_LIST="$DISABLE_LIST $EMAIL"
    fi
  fi

  USED_GB="$(awk -v b="$TOTAL" 'BEGIN{printf "%.2f", b/1073741824}')"
  QUOTA_GB="$(awk -v b="$QUOTA" 'BEGIN{printf "%.0f", b/1073741824}')"
  LEFT_GB="$(awk -v t="$TOTAL" -v q="$QUOTA" 'BEGIN{d=(q-t)/1073741824; if(d<0)d=0; printf "%.2f", d}')"
  EXP_D="$(date -d "@$EXPIRY" +%Y-%m-%d 2>/dev/null || echo '?')"
  ST="ACTIVE"; [ -f "$DF" ] && ST="DISABLED"
  case " $DISABLE_LIST " in *" $EMAIL "*) ST="DISABLED (this run)" ;; esac
  echo "$NAME: $USED_GB / $QUOTA_GB GB (left $LEFT_GB) — expires $EXP_D — $ST" >> "$STATUS_TMP"
done < "$REG"

if [ -n "$DISABLE_LIST" ]; then
  cp "$CFG" "$CFG.bak.quota-$(date +%s)"
  DISABLE_LIST="$DISABLE_LIST" TAG="$TAG" CFG="$CFG" python3 - <<'PYEOF'
import json, os
cfg = json.load(open(os.environ["CFG"]))
kill = set(os.environ["DISABLE_LIST"].split())
for ib in cfg.get("inbounds", []):
    if ib.get("tag") == os.environ["TAG"]:
        st = ib.get("settings", {})
        st["clients"] = [c for c in st.get("clients", []) if c.get("email") not in kill]
json.dump(cfg, open(os.environ["CFG"], "w"), indent=2)
PYEOF
  if "$XRAY" -test -config "$CFG" >/dev/null 2>&1; then
    systemctl restart xray
    for e in $DISABLE_LIST; do touch "$STATE_DIR/$e.disabled"; done
  else
    last="$(ls -t "$CFG".bak.quota-* 2>/dev/null | head -1)"
    [ -n "$last" ] && cp "$last" "$CFG"
    echo "WARNING: disable postponed (config test failed) $(date -Is)" >> "$STATUS_TMP"
  fi
fi

{ echo "GOLDENSKY shop keys — status $(date -Is)"; cat "$STATUS_TMP"; } > "$STATUS"
rm -f "$STATUS_TMP"
