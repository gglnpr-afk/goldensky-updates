#!/bin/bash
# GOLDENSKY Temp Mail — FirstByte merge step.
# Run ON the FirstByte box AFTER /tmp/tokyo-gateway.db and /tmp/sg-gateway.db
# have been copied over from the old Tokyo / SG boxes.
# Merges both old address DBs into this box's gateway DB (tokens + recovery
# codes move with them). The merge tool backs up the target DB first and
# never overwrites an existing address.
set -e
[ "$(id -u)" != "0" ] && { echo "Run with sudo"; exit 1; }
for f in /tmp/tokyo-gateway.db /tmp/sg-gateway.db; do
  [ -f "$f" ] || { echo "MISSING: $f — copy it from the old box first"; exit 1; }
done
curl -fsSL https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/merge-gateway-db.py -o /tmp/merge-gateway-db.py
systemctl stop gsmail
python3 /tmp/merge-gateway-db.py /var/lib/gsmail/gateway.db /tmp/tokyo-gateway.db /tmp/sg-gateway.db
systemctl start gsmail
sleep 1
echo
curl -fsS http://127.0.0.1:8090/health && echo
echo "DONE — addresses count above should be Tokyo + SG totals."
