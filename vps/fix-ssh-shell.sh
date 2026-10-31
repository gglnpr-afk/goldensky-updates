#!/usr/bin/env bash
# fix-ssh-shell.sh — GOLDENSKY SG-FREE session-drop fix.
# Evidence (auth.log, 2026-10-31): goldenskyvpn sessions lived 41s and
# 1s, each logging "nologin: Attempted login by goldenskyvpn" right
# after auth. The account's shell was /usr/sbin/nologin, which exits
# the instant the app opens its session channel, so the app treats
# the connection as broken and reconnects in a loop (connect/disconnect
# flapping). sshd closed nothing itself; the bridge never restarted.
# Fix: a sleep-forever shell — session/exec channels stay open, but
# nothing can ever execute (no prompt, no commands).
set -uo pipefail
[ "$(id -u)" = "0" ] || { echo "Run as root (sudo)."; exit 1; }

cat > /usr/local/bin/gs-noshell <<'EOF'
#!/bin/sh
# GOLDENSKY free-key shell: never runs commands, just holds the channel.
while :; do sleep 3600; done
EOF
chmod 755 /usr/local/bin/gs-noshell
usermod -s /usr/local/bin/gs-noshell goldenskyvpn
grep "^goldenskyvpn:" /etc/passwd
echo
echo "=== SHELL FIXED: session channels now stay open, nothing can execute ==="
echo "Reconnect the SG-FREE key and watch the timer pass 3 minutes."
