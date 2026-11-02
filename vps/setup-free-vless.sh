#!/usr/bin/env bash
# setup-free-vless.sh — GOLDENSKY kit: free VLESS+WS+TLS key with a hard
# data quota (300 GiB total pool) behind the Cloudflare tunnel, on its
# OWN subdomain: free.chithinphyu.info
#
# Design (why it looks like this): the pool must be metered, and the
# metering must not depend on Xray's internal traffic counters (their
# behavior could not be reliably verified from the build sandbox, whose
# network is intercepted). So metering lives in a tiny relay the
# traffic passes through — the same pattern as the SSH free pool's
# byte-counting bridge, which is already proven in production:
#
#   phone -> Cloudflare edge -> cloudflared tunnel
#         -> gs-meter relay (127.0.0.1:3458, counts every byte)
#         -> Xray vless-free inbound (127.0.0.1:3457, path /vless)
#
# What it does (all additive, existing inbounds/customers untouched):
# - Adds a DEDICATED VLESS+WS inbound on 127.0.0.1:3457 (tag
#   "vless-free") with ONE client (email "free300", fresh UUID).
# - Installs gs-meter.py as a systemd service (gs-meter) on :3458,
#   keeping the cumulative pool total in /var/lib/gs-free/bytes.txt.
# - Installs gs-free-guard.sh (cron, every 5 min): when the total
#   reaches 300 GiB it REMOVES the free client (backup + xray -test
#   gate first) and the key stops working for everyone.
#   Usage anytime: cat /root/vless-free-usage.txt
# - Xray config is backed up first; `xray -test` must pass before
#   restart; on any failure the backup is restored.
#
# ONE MANUAL STEP (Cloudflare dashboard, Zero Trust -> Tunnels ->
# goldensky-fb -> Public Hostnames -> Add):
#   free.chithinphyu.info  ->  http://127.0.0.1:3458
# Without that route the key cannot be reached from the internet.
#
# RE-RUNNING = RENEW: fresh UUID, usage counter reset, key re-armed.
# The old printed link dies the moment you re-run — and servers.json
# must be updated with the new link before customers get it again.
#
# Usage:  sudo bash setup-free-vless.sh
set -uo pipefail

CFG="${GS_CFG:-/usr/local/etc/xray/config.json}"
XRAY="${GS_XRAY:-/usr/local/bin/xray}"
EMAIL="free300"
TAG="vless-free"
PORT=3457
RELAY_PORT=3458
WS_PATH="/vless"
DOMAIN="${GS_FREE_DOMAIN:-free.chithinphyu.info}"
NAME="GOLDENSKY-SG-FREE-300GB"
STATE_DIR=/var/lib/gs-free
GUARD_URL="https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/gs-free-guard.sh"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
[ -f "$CFG" ] || { echo "Xray config not found: $CFG"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
[ -x "$XRAY" ] || { echo "xray binary not found: $XRAY"; exit 1; }
if ss -tln 2>/dev/null | grep -q ":$PORT " && ! grep -q "\"$TAG\"" "$CFG"; then
  echo "Port $PORT is used by something else — aborting."; exit 1
fi
if ss -tln 2>/dev/null | grep -q ":$RELAY_PORT " && ! systemctl is-active --quiet gs-meter 2>/dev/null; then
  echo "Port $RELAY_PORT is used by something else — aborting."; exit 1
fi

UUID="$(cat /proc/sys/kernel/random/uuid)"
BAK="$CFG.bak.free-$(date +%s)"
cp "$CFG" "$BAK"
echo "Config backed up: $BAK"

UUID="$UUID" EMAIL="$EMAIL" TAG="$TAG" PORT="$PORT" WS_PATH="$WS_PATH" CFG="$CFG" python3 - <<'PYEOF'
import json, os
cfg = json.load(open(os.environ["CFG"]))
uuid, email, tag = os.environ["UUID"], os.environ["EMAIL"], os.environ["TAG"]
port, wpath = int(os.environ["PORT"]), os.environ["WS_PATH"]
ib = cfg.setdefault("inbounds", [])
# Dedicated free inbound (replace on re-run = renew, fresh UUID).
ib[:] = [i for i in ib if i.get("tag") != tag]
ib.append({
    "tag": tag, "listen": "127.0.0.1", "port": port, "protocol": "vless",
    "settings": {"clients": [{"id": uuid, "email": email}], "decryption": "none"},
    "streamSettings": {"network": "ws", "security": "none",
                       "wsSettings": {"path": wpath}},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
})
json.dump(cfg, open(os.environ["CFG"], "w"), indent=2)
print("Config updated: vless-free inbound on 127.0.0.1:%d" % port)
PYEOF
if [ $? -ne 0 ]; then
  echo "Config edit FAILED — restoring backup, nothing changed."
  cp "$BAK" "$CFG"; exit 1
fi

if ! "$XRAY" -test -config "$CFG" >/dev/null 2>&1; then
  echo "xray -test FAILED — restoring backup, nothing changed."
  cp "$BAK" "$CFG"; exit 1
fi
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
  echo "xray did not start — restoring backup."
  cp "$BAK" "$CFG"; systemctl restart xray; exit 1
fi

echo "=== meter relay ==="
mkdir -p "$STATE_DIR"
cat > /usr/local/bin/gs-meter.py <<'PYEOF'
#!/usr/bin/env python3
"""gs-meter: byte-counting TCP relay for the GOLDENSKY free VLESS pool.

Listens on 127.0.0.1:3458 (cloudflared points here), forwards to the
Xray vless-free inbound on 127.0.0.1:3457, and keeps a cumulative byte
total (both directions) in /var/lib/gs-free/bytes.txt. The total is the
pool usage that gs-free-guard.sh enforces the 300 GiB quota against.
"""
import asyncio, os, signal, sys, time

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("GS_METER_LISTEN_PORT", "3458"))
TARGET_HOST = "127.0.0.1"
TARGET_PORT = int(os.environ.get("GS_METER_TARGET_PORT", "3457"))
BYTES_FILE = os.environ.get("GS_METER_BYTES_FILE", "/var/lib/gs-free/bytes.txt")

total = 0
last_flush_val = 0
last_flush_time = 0.0

def load_total():
    global total, last_flush_val
    try:
        with open(BYTES_FILE) as f:
            total = int(f.read().strip() or "0")
    except Exception:
        total = 0
    last_flush_val = total

def flush():
    global last_flush_val, last_flush_time
    try:
        tmp = BYTES_FILE + ".tmp"
        with open(tmp, "w") as f:
            f.write(str(total))
        os.replace(tmp, BYTES_FILE)
        last_flush_val = total
        last_flush_time = time.monotonic()
    except Exception:
        pass

def count(n):
    global total
    total += n
    if total - last_flush_val >= 65536 or time.monotonic() - last_flush_time >= 5:
        flush()

async def pump(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            count(len(data))
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass

async def handle(reader, writer):
    try:
        up_reader, up_writer = await asyncio.open_connection(TARGET_HOST, TARGET_PORT)
    except Exception:
        try:
            writer.close()
        except Exception:
            pass
        return
    t1 = asyncio.ensure_future(pump(reader, up_writer))
    t2 = asyncio.ensure_future(pump(up_reader, writer))
    done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()

async def main():
    load_total()
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    print("gs-meter listening %s:%d -> %s:%d (total=%d)" %
          (LISTEN_HOST, LISTEN_PORT, TARGET_HOST, TARGET_PORT, total), flush=True)
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, lambda: (flush(), sys.exit(0)))
        except Exception:
            pass
    try:
        loop.run_until_complete(main())
    finally:
        flush()
PYEOF
chmod +x /usr/local/bin/gs-meter.py
python3 -c "import ast; ast.parse(open('/usr/local/bin/gs-meter.py').read())" \
  && echo "meter syntax OK" || { echo "meter syntax FAILED"; exit 1; }

cat > /etc/systemd/system/gs-meter.service <<'UNITEOF'
[Unit]
Description=GOLDENSKY free-pool byte meter relay (3458 -> 3457)
After=network.target xray.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/gs-meter.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNITEOF

# Renew semantics: pool counter restarts from zero for the new key.
# Stop the meter FIRST (its shutdown flush would otherwise overwrite
# the reset with the old in-memory total), then reset, then start it.
systemctl stop gs-meter 2>/dev/null || true
echo 0 > "$STATE_DIR/bytes.txt"
rm -f "$STATE_DIR/disabled"
systemctl daemon-reload
systemctl enable gs-meter >/dev/null 2>&1 || true
systemctl restart gs-meter
sleep 1
systemctl is-active --quiet gs-meter && echo "meter service active" \
  || { echo "ERROR: gs-meter service did not start."; exit 1; }

# Proof: a WebSocket upgrade through the relay must get Xray's 101.
PROOF="$(python3 - "$RELAY_PORT" "$WS_PATH" "$DOMAIN" <<'PYEOF'
import socket, sys
port, path, host = int(sys.argv[1]), sys.argv[2], sys.argv[3]
req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
       "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
       "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host))
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=8)
    s.settimeout(8)
    s.sendall(req.encode())
    data = s.recv(200).decode("latin1", "replace")
    s.close()
    print(data.split("\r\n")[0])
except Exception as e:
    print("ERROR: %s" % e)
PYEOF
)"
case "$PROOF" in
  *"101"*) echo "METER+WS PROOF OK ($PROOF)" ;;
  *) echo "WARNING: WS proof unexpected: $PROOF (check xray + meter logs)" ;;
esac

echo "=== quota guard ==="
if [ -f "$HERE/gs-free-guard.sh" ]; then
  cp "$HERE/gs-free-guard.sh" /usr/local/bin/gs-free-guard.sh
else
  curl -sL "$GUARD_URL" -o /usr/local/bin/gs-free-guard.sh || { echo "Guard download failed."; exit 1; }
fi
chmod +x /usr/local/bin/gs-free-guard.sh
echo '*/5 * * * * root /usr/local/bin/gs-free-guard.sh >/dev/null 2>&1' > /etc/cron.d/gs-free-guard
/usr/local/bin/gs-free-guard.sh || true

LINK="$(python3 - "$UUID" "$DOMAIN" "$WS_PATH" "$NAME" <<'PYEOF'
import sys, urllib.parse
uuid, domain, path, name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
enc_path = urllib.parse.quote(path, safe="/")
enc_name = urllib.parse.quote(name, safe="")
q = ("encryption=none&security=tls&sni=" + domain + "&fp=chrome&alpn=http%2F1.1"
     "&type=ws&host=" + domain + "&path=" + enc_path)
print("vless://%s@%s:443?%s#%s" % (uuid, domain, q, enc_name))
PYEOF
)"

{
  echo "$LINK"
  echo "Quota: 300 GiB total pool (auto-disables when used up)"
  echo "Usage check: cat /root/vless-free-usage.txt"
} > /root/my-vless-free.txt

echo
echo "=== FREE VLESS KEY LIVE (300 GiB pool) ==="
echo "$LINK"
echo
echo "Usage anytime:  cat /root/vless-free-usage.txt"
echo "Renew later:    re-run this script (new link, counter reset)"
echo "TODO (once):    Cloudflare tunnel route  $DOMAIN -> http://127.0.0.1:$RELAY_PORT"
echo "NEXT: test the link in GOLDENSKY first — do not distribute yet."
