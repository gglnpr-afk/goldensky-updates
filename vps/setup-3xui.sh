#!/usr/bin/env bash
# setup-3xui.sh — GOLDENSKY kit: install the 3x-ui panel (NON-interactive)
# alongside the EXISTING kit Xray on this server, for GB-quota key trials.
#
# WHY: the GOLDENSKY app cannot enforce data limits. 3x-ui can: each
# client gets a traffic quota (GB) + expiry and is auto-disabled when
# the quota is used up. This script is the TRIAL install.
#
# COEXISTENCE — READ FIRST:
# - 3x-ui runs its OWN Xray binary with its OWN config/database
#   (/usr/local/x-ui, /etc/x-ui). It does NOT read or modify
#   /usr/local/etc/xray/config.json — the existing SS / VMess / VLESS
#   inbounds and all current customer keys keep working untouched.
# - Inside the panel, only use FREE ports. Ports already used on the
#   kit servers: 22, 8388, 8080, 25574, 443, 80. The trial inbound
#   port for this kit is 10086 — keep panel inbounds on new ports.
# - The panel itself listens on 23947 (HTTP for the trial — log in
#   only from your own phone, use the generated strong password,
#   and never share the panel URL publicly).
#
# Lightsail CONSOLE step (before or right after running this):
# open TCP 23947 (panel) and TCP 10086 (trial inbound) in
# Instance -> Networking -> Firewall.
#
# The installer runs unattended (official XUI_NONINTERACTIVE mode,
# SQLite DB, no SSL for the trial). Login credentials are RANDOM,
# printed once at the end and saved to /root/x-ui-login.txt (0600).
#
# Removal:  systemctl disable --now x-ui; rm -rf /usr/local/x-ui /etc/x-ui /root/x-ui-login.txt
#
# Usage:  sudo bash setup-3xui.sh
set -uo pipefail

PANEL_PORT=23947
TRIAL_PORT=10086
INSTALLER_URL="https://cdn.jsdelivr.net/gh/mhsanaei/3x-ui@master/install.sh"

if [ "$(id -u)" != "0" ]; then echo "Run as root (sudo)."; exit 1; fi
if [ -d /usr/local/x-ui ]; then echo "3x-ui already installed (/usr/local/x-ui exists) — aborting."; exit 1; fi

for p in "$PANEL_PORT" "$TRIAL_PORT"; do
  if ss -tln 2>/dev/null | grep -q ":$p "; then echo "Port $p is already in use — aborting."; exit 1; fi
done

echo "Downloading the official 3x-ui installer..."
curl -sL "$INSTALLER_URL" -o /tmp/xui-install.sh || { echo "Download failed."; exit 1; }
[ -s /tmp/xui-install.sh ] || { echo "Installer file is empty."; exit 1; }

echo "Installing (unattended — this takes a minute or two)..."
XUI_NONINTERACTIVE=1 \
XUI_DB_TYPE=sqlite \
XUI_SSL_MODE=none \
XUI_PANEL_PORT=$PANEL_PORT \
  bash /tmp/xui-install.sh 2>&1 | tee /root/x-ui-install.log | tail -5

if [ ! -d /usr/local/x-ui ]; then echo "Install FAILED — see /root/x-ui-install.log"; exit 1; fi

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow ${PANEL_PORT}/tcp >/dev/null; ufw allow ${TRIAL_PORT}/tcp >/dev/null
  echo "ufw: opened $PANEL_PORT + $TRIAL_PORT"
fi

# Pull the generated access details out of the installer log.
{
  echo "Panel URL path info (from installer):"
  grep -iE "access url|username|password|port|webbasepath|base path" /root/x-ui-install.log | tail -12
  echo
  echo "Panel port: $PANEL_PORT  |  Trial inbound port: $TRIAL_PORT"
  echo "Full install log: /root/x-ui-install.log"
} > /root/x-ui-login.txt
chmod 600 /root/x-ui-login.txt

echo
echo "=== 3x-ui INSTALLED ==="
systemctl is-active x-ui >/dev/null 2>&1 && echo "Service: active" || echo "Service: NOT active — check /root/x-ui-install.log"
cat /root/x-ui-login.txt
echo
echo "NEXT: Lightsail console -> Tokyo instance -> Networking -> Firewall"
echo "open TCP $PANEL_PORT and TCP $TRIAL_PORT, then open the panel URL"
echo "in your phone browser and SCREENSHOT the login info above."
echo "Existing GOLDENSKY servers on this box are untouched."
