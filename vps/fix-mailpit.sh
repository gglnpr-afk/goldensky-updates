#!/bin/bash
# GOLDENSKY Temp Mail — Mailpit port fix (run on BOTH VPSes)
# Bug: Mailpit v1.32 renamed env vars (MP_SMTP -> MP_SMTP_BIND_ADDR,
# MP_LISTEN -> MP_UI_BIND_ADDR), so the setup unit's env was ignored and
# SMTP stayed on the default port 1025 instead of 25 (no mail could arrive).
# Fix: rewrite the unit with correct env names AND explicit CLI flags.
set -e
if [ "$(id -u)" != "0" ]; then echo "Run with sudo"; exit 1; fi
cat > /etc/systemd/system/mailpit.service <<'EOF'
[Unit]
Description=Mailpit (GOLDENSKY Temp Mail store)
After=network.target
[Service]
Environment=MP_MAX_MESSAGES=0
Environment=MP_DATABASE=/var/lib/mailpit/mailpit.db
Environment=MP_SMTP_BIND_ADDR=0.0.0.0:25
Environment=MP_UI_BIND_ADDR=127.0.0.1:8025
Environment=MP_MAX_MESSAGE_SIZE=25
ExecStart=/usr/local/bin/mailpit --smtp 0.0.0.0:25 --listen 127.0.0.1:8025 --database /var/lib/mailpit/mailpit.db --max 0 --max-message-size 25
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart mailpit
sleep 2
echo "== mailpit listeners =="
ss -tlnp | grep mailpit || true
echo
timeout 3 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/25' && echo "PORT 25 OK — SMTP is listening"
echo "DONE. Gmail retries queued mail automatically — the test mails"
echo "should arrive within a few minutes (max ~30 min)."
