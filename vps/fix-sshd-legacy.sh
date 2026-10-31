#!/bin/bash
# GOLDENSKY: let OLD SSH clients (HTTP Injector and friends) negotiate
# with this modern OpenSSH. Without this, Injector dies at the host-key
# step: "SSH: Unknown key type rsa-sha2-256" (seen 2026-10-31 10:33).
# Appends legacy algorithms (+ syntax = extend defaults, not replace).
# sshd -t gate + sshd -T self-verification (drop-in name starts 00- so
# it wins under OpenSSH first-occurrence-wins; the -T check proves it).
set -e
F=/etc/ssh/sshd_config.d/00-gs-legacy.conf
cat > "$F" <<'EOF'
# GOLDENSKY legacy algorithms for old SSH clients (HTTP Injector etc.)
KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
Ciphers +aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc
MACs +hmac-sha1,hmac-md5
HostKeyAlgorithms +ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa
EOF
if ! sshd -t; then
  echo "CONFIG REJECTED - removing drop-in, sshd untouched"
  rm -f "$F"
  sshd -t
  exit 1
fi
systemctl reload ssh 2>/dev/null || systemctl restart ssh
sleep 1
echo "--- effective algorithms ---"
sshd -T | grep -E "^(hostkeyalgorithms|ciphers|macs|kexalgorithms)" | cut -c1-110
if sshd -T | grep -q "^hostkeyalgorithms.*ssh-rsa"; then
  echo ""
  echo "=== LEGACY OK: HTTP Injector can now negotiate ==="
  echo "Retry Injector with the SG-FREE key."
else
  echo ""
  echo "WARNING: another config file overrides this one - send me this output"
fi
