#!/bin/bash
# GOLDENSKY Temp Mail — one-shot setup for the FirstByte box (46.8.125.49).
# Hosts ALL FOUR own domains on this one server:
#   luciferdead.com (primary, new) + secondfamilys.com (new)
#   + busterzone.mobi + donatekey.realty (migrated from Tokyo / SG)
# API hosts (unchanged names, so existing app installs keep working):
#   mailapi.luciferdead.com, mailapi.busterzone.mobi, mailapi.donatekey.realty
# Just downloads and runs the standard setup-tempmail.sh with those args.
set -e
curl -fsSL https://raw.githubusercontent.com/gglnpr-afk/goldensky-updates/main/vps/setup-tempmail.sh -o /tmp/setup-tempmail.sh
sudo bash /tmp/setup-tempmail.sh \
  luciferdead.com \
  luciferdead.com,secondfamilys.com,busterzone.mobi,donatekey.realty \
  mailapi.luciferdead.com,mailapi.busterzone.mobi,mailapi.donatekey.realty
