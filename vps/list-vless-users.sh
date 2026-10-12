#!/bin/bash
# ============================================================
# List all VLESS users on the GOLDENSKY VPS.
# Usage:  bash list-vless-users.sh
# ============================================================

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:  sudo bash list-vless-users.sh"
  exit 1
fi

echo "================ VLESS USERS ================"
if [ -f /root/vless-users.txt ] && [ -s /root/vless-users.txt ]; then
  printf "%-40s %-15s %s\n" "UUID" "NAME" "ADDED"
  echo "--------------------------------------------------------------"
  while read -r uuid name date; do
    printf "%-40s %-15s %s\n" "$uuid" "$name" "$date"
  done < /root/vless-users.txt
else
  echo "(no users recorded yet — new users added with"
  echo " add-vless-user.sh will appear here)"
fi
echo "============================================="
echo ""
echo "xray status: $(systemctl is-active xray)"
