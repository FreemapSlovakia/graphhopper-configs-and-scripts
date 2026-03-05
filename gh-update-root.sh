#!/bin/bash
set -euo pipefail

cd /opt/graphhopper

# Prevent overlapping cron runs at the root-wrapper level.
exec 9>/var/lock/gh-update-root.lock
if ! flock -n 9; then
  echo "Another gh-update-root run is already active"
  exit 0
fi

su -c ./gh-update.sh freemap |& ts '[%Y-%m-%d %H:%M:%S]' >> gh-update.log
