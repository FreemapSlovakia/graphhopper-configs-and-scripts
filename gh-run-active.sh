#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

active="$(cat gh.active 2>/dev/null || true)"
case "$active" in
  a|b) ;;
  *)
    echo "Invalid or missing gh.active (expected 'a' or 'b')"
    exit 1
    ;;
esac


active_pattern="java.*graphhopper.*config-freemap\\.${active}\\.yml"

# Keep active running if already up.
if pgrep -f "$active_pattern" >/dev/null; then
  echo "Active instance '${active}' is already running"
  exit 0
fi

echo "Starting active instance '${active}'"

nohup java -Xms1g -Xmx4g -jar graphhopper-web-11.0.jar server "config-freemap.${active}.yml" >> gh-server.log 2>&1 < /dev/null &
