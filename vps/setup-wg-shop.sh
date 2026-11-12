#!/bin/bash
# setup-wg-shop.sh — WG customer-key shop on wg500 / UDP 500 (FirstByte JP)
# Base server (created only if missing) + add-wg minter + gs-wg-guard (quota/expiry, cron 5 min).
# Adds wg500 only; never touches Xray / TUIC / Hysteria services.
# Usage: bash setup-wg-shop.sh [HOST]   (default jp.mobileking.vip)
# HOST must be a DNS A record pointing at this server, DNS-only (grey cloud) -
# a proxied (orange cloud) record cannot carry WireGuard UDP.
set -e
[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }

PORT=500
HOST="${1:-jp.mobileking.vip}"
WGCONF=/etc/wireguard/wg500.conf

if [ ! -f "$WGCONF" ]; then
  echo "No wg500 yet - creating the base server..."
  if ss -lun | grep -q ":$PORT "; then echo "UDP $PORT already in use - aborting"; exit 1; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard-tools iptables >/dev/null
  WANIF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$WANIF" ] || WANIF=eth0
  mkdir -p /etc/wireguard
  umask 077
  S_PRIV=$(wg genkey); S_PUB=$(printf %s "$S_PRIV" | wg pubkey)
  C_PRIV=$(wg genkey); C_PUB=$(printf %s "$C_PRIV" | wg pubkey)
  cat > "$WGCONF" <<EOF
[Interface]
PrivateKey = $S_PRIV
Address = 10.66.0.1/24
ListenPort = $PORT
PostUp = iptables -A FORWARD -i wg500 -j ACCEPT; iptables -t nat -A POSTROUTING -o $WANIF -j MASQUERADE
PostDown = iptables -D FORWARD -i wg500 -j ACCEPT; iptables -t nat -D POSTROUTING -o $WANIF -j MASQUERADE

# owner
[Peer]
PublicKey = $C_PUB
AllowedIPs = 10.66.0.2/32
EOF
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg500.conf
  sysctl -p /etc/sysctl.d/99-wg500.conf >/dev/null
  systemctl enable wg-quick@wg500 >/dev/null 2>&1 || true
  systemctl restart wg-quick@wg500
  urlenc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }
  OLINK="wireguard://$(urlenc "$C_PRIV")@$HOST:$PORT?address=10.66.0.2%2F32&presharedkey=&publickey=$(urlenc "$S_PUB")&mtu=1280#WG500-JP"
  printf '%s\n' "$OLINK" > /root/my-wg500.txt
  chmod 600 /root/my-wg500.txt
  echo "Owner key link saved in /root/my-wg500.txt"
else
  echo "wg500 already exists - keeping the server key and all existing peers."
fi

mkdir -p /etc/wireguard /var/lib/gs-wg /root/wg-keys
touch /etc/wireguard/clients.db
printf '%s\n' "$HOST" > /etc/wireguard/host.txt
echo "Endpoint host for all customer keys: $HOST:$PORT"
echo "(its DNS A record must point at this server and stay DNS-only / grey cloud)"

cat > /usr/local/bin/add-wg <<'EOF_ADDWG'
#!/bin/bash
# add-wg <name> [GB=100] [days=30] — mint or RENEW a customer WireGuard key (wg500, UDP 500)
# GB=0 = unlimited traffic; days=0 = no expiry. Re-running the same name renews it:
# old peer removed, fresh key issued, usage reset, expiry counted from today.
set -e
umask 077
IFACE=wg500
PORT=500
HOST="${WG_HOST:-}"
HOSTFILE="${HOSTFILE:-/etc/wireguard/host.txt}"
if [ -z "$HOST" ] && [ -f "$HOSTFILE" ]; then HOST=$(head -1 "$HOSTFILE" | tr -d ' \r\n'); fi
HOST="${HOST:-jp.mobileking.vip}"
WGCONF="${WGCONF:-/etc/wireguard/wg500.conf}"
REG="${REG:-/etc/wireguard/clients.db}"
KEYDIR="${KEYDIR:-/root/wg-keys}"
USAGEDIR="${USAGEDIR:-/var/lib/gs-wg}"
DB="$USAGEDIR/usage.tsv"

NAME="${1:-}"
GB="${2:-100}"
DAYS="${3:-30}"
[ -n "$NAME" ] || { echo "Usage: add-wg <name> [GB=100] [days=30]"; exit 1; }
printf %s "$NAME" | grep -Eq '^[A-Za-z0-9_-]+$' || { echo "Name: A-Z a-z 0-9 _ - only"; exit 1; }
printf %s "$GB" | grep -Eq '^[0-9]+$' || { echo "GB must be a number"; exit 1; }
printf %s "$DAYS" | grep -Eq '^[0-9]+$' || { echo "days must be a number"; exit 1; }
[ -f "$WGCONF" ] || { echo "$WGCONF not found - run setup-wg-shop.sh first"; exit 1; }
mkdir -p "$KEYDIR" "$USAGEDIR" "$(dirname "$REG")"
touch "$REG" "$DB"

remove_peer() { # $1 = pubkey
  wg set "$IFACE" peer "$1" remove 2>/dev/null || true
  PUB="$1" CONF="$WGCONF" python3 - <<'PYEOF'
import os
pub = os.environ["PUB"]; path = os.environ["CONF"]
blocks = open(path).read().split("\n\n")
kept = [b for b in blocks if ("PublicKey = " + pub) not in b]
open(path, "w").write("\n\n".join(kept).rstrip() + "\n")
PYEOF
}

# --- renew: drop this name's old peer + registry line + usage history ---
OLDPUB=$(awk -F'|' -v n="$NAME" '$1==n{print $2}' "$REG" | head -1)
if [ -n "$OLDPUB" ]; then
  remove_peer "$OLDPUB"
  awk -F'\t' -v p="$OLDPUB" '$1!=p' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
  awk -F'|' -v n="$NAME" '$1!=n' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
  echo "Renewing $NAME (old key removed)"
fi

# --- server public key (for the client link) ---
S_PRIV=$(awk '/^\[Interface\]/{f=1} f&&/^PrivateKey/{print $3; exit}' "$WGCONF")
[ -n "$S_PRIV" ] || { echo "Server PrivateKey not found in $WGCONF"; exit 1; }
S_PUB=$(printf %s "$S_PRIV" | wg pubkey)

# --- allocate the lowest free 10.66.0.x (x >= 2; .1 is the server) ---
IP=""
for i in $(seq 2 254); do
  cand="10.66.0.$i"
  if ! { awk -F'|' 'NF>2{print $3}' "$REG"; grep -oE '10\.66\.0\.[0-9]+' "$WGCONF" | sort -u; } | grep -qx "$cand"; then
    IP="$cand"; break
  fi
done
[ -n "$IP" ] || { echo "Subnet full (253 clients max)"; exit 1; }

# --- mint the keypair, add the peer live + persist it in the conf ---
C_PRIV=$(wg genkey); C_PUB=$(printf %s "$C_PRIV" | wg pubkey)
wg set "$IFACE" peer "$C_PUB" allowed-ips "$IP/32"
printf '\n# %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "$NAME" "$C_PUB" "$IP" >> "$WGCONF"

# --- registry ---
LIMIT_BYTES=$(( GB * 1024 * 1024 * 1024 ))
NOW=$(date +%s)
if [ "$DAYS" -gt 0 ]; then EXP=$(( NOW + DAYS * 86400 )); else EXP=0; fi
echo "$NAME|$C_PUB|$IP|$LIMIT_BYTES|$EXP|$NOW|ACTIVE" >> "$REG"

# --- client link + conf file ---
urlenc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }
LINK="wireguard://$(urlenc "$C_PRIV")@$HOST:$PORT?address=$IP%2F32&presharedkey=&publickey=$(urlenc "$S_PUB")&mtu=1280#WG-$NAME"
cat > "$KEYDIR/$NAME.txt" <<CLIENTEOF
$LINK

[Interface]
PrivateKey = $C_PRIV
Address = $IP/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $S_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = $HOST:$PORT
CLIENTEOF
chmod 600 "$KEYDIR/$NAME.txt"

echo ""
echo "=== WG key for $NAME ($IP) — ${GB}GB, ${DAYS} days ==="
echo "$LINK"
echo "=== saved in $KEYDIR/$NAME.txt ==="
if [ "$EXP" -gt 0 ]; then echo "Expires: $(date -d "@$EXP" '+%Y-%m-%d')"; fi
EOF_ADDWG
chmod +x /usr/local/bin/add-wg

cat > /usr/local/bin/gs-wg-guard.sh <<'EOF_GUARD'
#!/bin/bash
# gs-wg-guard.sh — quota + expiry enforcement for wg500 customers (run from cron, every 5 min)
# Accounting is reset-safe: per-peer cumulative usage is built from deltas of
# `wg show wg500 transfer` counters, so an interface restart never loses or
# double-counts traffic. Status report: /root/wg-usage.txt
IFACE=wg500
export WGCONF="${WGCONF:-/etc/wireguard/wg500.conf}"
export REG="${REG:-/etc/wireguard/clients.db}"
export USAGEDIR="${USAGEDIR:-/var/lib/gs-wg}"
export STATUS="${STATUS:-/root/wg-usage.txt}"
export IFACE
mkdir -p "$USAGEDIR"
touch "$REG"

python3 - <<'PYEOF'
import os, subprocess, time
from datetime import datetime

IFACE   = os.environ["IFACE"]
WGCONF  = os.environ["WGCONF"]
REG     = os.environ["REG"]
DB      = os.path.join(os.environ["USAGEDIR"], "usage.tsv")
STATUS  = os.environ["STATUS"]
NOW     = int(time.time())
GIB     = 1024 ** 3

# ---- load cumulative usage: pub -> [cum_rx, cum_tx, last_rx, last_tx] ----
usage = {}
if os.path.exists(DB):
    for line in open(DB):
        p = line.rstrip("\n").split("\t")
        if len(p) == 5:
            try: usage[p[0]] = [int(x) for x in p[1:]]
            except ValueError: pass

# ---- pull live counters and fold in deltas (reset-safe) ----
try:
    out = subprocess.run(["wg", "show", IFACE, "transfer"],
                         capture_output=True, text=True, timeout=15).stdout
except Exception:
    out = ""
for line in out.strip().split("\n"):
    if not line.strip():
        continue
    f = line.split("\t")
    if len(f) != 3:
        continue
    pub, rx, tx = f[0], int(f[1]), int(f[2])
    if pub in usage:
        crx, ctx, lrx, ltx = usage[pub]
        crx += (rx - lrx) if rx >= lrx else rx
        ctx += (tx - ltx) if tx >= ltx else tx
        usage[pub] = [crx, ctx, rx, tx]
    else:
        usage[pub] = [0, 0, rx, tx]  # first sight: baseline, count from now

with open(DB, "w") as fh:
    for pub, v in usage.items():
        fh.write(pub + "\t" + "\t".join(str(x) for x in v) + "\n")

def used_bytes(pub):
    v = usage.get(pub)
    return (v[0] + v[1]) if v else 0

def drop_peer(pub):
    subprocess.run(["wg", "set", IFACE, "peer", pub, "remove"],
                   capture_output=True, timeout=15)
    blocks = open(WGCONF).read().split("\n\n")
    kept = [b for b in blocks if ("PublicKey = " + pub) not in b]
    open(WGCONF, "w").write("\n\n".join(kept).rstrip() + "\n")

# ---- registry: name|pub|ip|limit_bytes|expiry_epoch|created_epoch|state ----
rows = []
if os.path.exists(REG):
    for line in open(REG):
        line = line.rstrip("\n")
        if not line:
            continue
        p = line.split("|")
        if len(p) == 7:
            rows.append(p)

changed = False
for r in rows:
    name, pub, ip, limit, expiry, created, state = r
    if state != "ACTIVE":
        continue
    limit, expiry = int(limit), int(expiry)
    if expiry > 0 and NOW > expiry:
        drop_peer(pub); r[6] = "EXPIRED"; changed = True
    elif limit > 0 and used_bytes(pub) >= limit:
        drop_peer(pub); r[6] = "QUOTA-FULL"; changed = True

if changed:
    with open(REG, "w") as fh:
        for r in rows:
            fh.write("|".join(r) + "\n")

# ---- status report ----
lines = ["WG500 customers - " + datetime.now().strftime("%Y-%m-%d %H:%M"), ""]
if not rows:
    lines.append("(no customers yet - mint with: add-wg <name> [GB] [days])")
for r in sorted(rows, key=lambda x: x[0]):
    name, pub, ip, limit, expiry, created, state = r
    limit, expiry = int(limit), int(expiry)
    u = used_bytes(pub) / GIB
    lim = ("%.0f GB" % (limit / GIB)) if limit > 0 else "Unlimited"
    exp = datetime.fromtimestamp(expiry).strftime("%Y-%m-%d") if expiry > 0 else "never"
    lines.append("%s (%s): Used %.2f GB / %s, expires %s, State %s"
                 % (name, ip, u, lim, exp, state))
with open(STATUS, "w") as fh:
    fh.write("\n".join(lines) + "\n")
PYEOF
EOF_GUARD
chmod +x /usr/local/bin/gs-wg-guard.sh

( crontab -l 2>/dev/null | grep -v 'gs-wg-guard' ; echo '*/5 * * * * /usr/local/bin/gs-wg-guard.sh >/dev/null 2>&1' ) | crontab -
/usr/local/bin/gs-wg-guard.sh || true

systemctl is-active wg-quick@wg500 || echo "WARNING: wg-quick@wg500 is not active"
echo ""
echo "=== WG SHOP READY (wg500, UDP 500, endpoint $HOST) ==="
echo "Mint a customer key : add-wg <name> [GB=100] [days=30]"
echo "Renew a key         : add-wg <name> [GB] [days]   (run it with the same name again)"
echo "Usage / status      : cat /root/wg-usage.txt"
echo "Customer key files  : /root/wg-keys/<name>.txt"
echo "The owner key (WG500-JP, 10.66.0.2) is unmanaged - no quota, no expiry."
