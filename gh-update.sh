#!/bin/bash
set -e

cd "$(dirname "$0")"

# Prevent overlapping updater runs (cron + manual, stale marker cleanup, etc).
exec 9>gh-update.lock
if ! flock -n 9; then
  echo "Already processing"
  exit 0
fi

trap 'echo Finished' EXIT INT TERM

remote_md5="$(wget -q -O - https://download.geofabrik.de/europe-latest.osm.pbf.md5)"

if [ -f europe-latest.osm.pbf.md5 ] && [ "$(cat europe-latest.osm.pbf.md5)" = "$remote_md5" ]
then
  echo "No update available"
  exit 0
fi

# TODO rather get it by listing active processes
active=$(test -f gh.active && cat gh.active || echo 'none')

echo "Active: $active"

echo "Downloading"

rm -f tmp/europe-latest.osm.pbf tmp/extract.pbf
wget -nv https://download.geofabrik.de/europe-latest.osm.pbf -P tmp

echo "Extracting"

osmium extract --set-bounds -p limit.geojson tmp/europe-latest.osm.pbf -o tmp/extract.pbf
rm tmp/europe-latest.osm.pbf

if [[ "$active" == "a" ]]
then
	next="b"
else
	next="a"
fi

echo "Importing: $next"

rm -rf /fm/sdata/graphhopper/graph-cache.${next} && mkdir -p /fm/sdata/graphhopper/graph-cache.${next}

java -Xmx40g -jar graphhopper-web-11.0.jar import "config-freemap.${next}.yml" > /dev/null 2>&1

echo "Starting: $next"

java -Xmx40g -jar graphhopper-web-11.0.jar server "config-freemap.${next}.yml" > /dev/null 2>&1 &

echo "$next" > gh.active

printf '%s\n' "$remote_md5" > europe-latest.osm.pbf.md5

# wait one minute for GH to become active
# TODO rather poll the service
echo Waiting

sleep 60

pkill -f "java.*graphhopper.*config-freemap\\.${active}\\.yml" || true

rm -f ./graphhopper.freemap.sk
ln -s ./graphhopper.freemap.sk.${next} ./graphhopper.freemap.sk

echo Success
