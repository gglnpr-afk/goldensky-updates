#!/bin/bash
# GOLDENSKY Temp Mail — FirstByte box: keep ONLY the two new domains.
# (User decision 2026-10-26: busterzone.mobi / donatekey.realty stay on
#  their existing Tokyo / SG boxes — no migration.)
# Re-runs the standard setup with just luciferdead.com + secondfamilys.com,
# which rewrites GS_DOMAINS and the Caddyfile to match. The FirstByte
# gateway DB is empty (0 addresses), so nothing is lost. Also removes the
# stray empty /tmp/tokyo-*.db copies made on this box by mistake earlier.
set -e
rm -f /tmp/tokyo-gateway.db /tmp/tokyo-mailpit.db /tmp/sg-gateway.db /tmp/sg-mailpit.db
curl -fsSL https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/setup-tempmail.sh -o /tmp/setup-tempmail.sh
sudo bash /tmp/setup-tempmail.sh \
  luciferdead.com \
  luciferdead.com,secondfamilys.com \
  mailapi.luciferdead.com
