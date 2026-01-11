#!/bin/bash
set -e

if [ -e europe-latest.osm.pbf.md5.candidate ]; then
  echo "Already processing"
  exit 0
fi

cleanup() {
  rm -f europe-latest.osm.pbf.md5.candidate

  echo Finished
}

trap cleanup EXIT INT TERM

wget -q -O europe-latest.osm.pbf.md5.candidate https://download.geofabrik.de/europe-latest.osm.pbf.md5

if [ -f europe-latest.osm.pbf.md5 ] && diff -q europe-latest.osm.pbf.md5 europe-latest.osm.pbf.md5.candidate > /dev/null
then
  echo "No update available"
  exit 0
fi

# TODO rather get it by listing active processes
active=`cat gh.active`

echo "Active: $active"

echo "Downloading"

rm -f tmp/europe-latest.osm.pbf tmp/extract.pbf
wget -nv https://download.geofabrik.de/europe-latest.osm.pbf -P tmp

echo "Extracting"

osmium extract --set-bounds -p limit.geojson tmp/europe-latest.osm.pbf -o tmp/extract.pbf
rm tmp/europe-latest.osm.pbf

if [[ "$active" == "a" ]]; then
	next="b"
else
	next="a"
fi

echo "Importing: $next"

rm -rf /fm/sdata/graphhopper/graph-cache.${next}
mkdir /fm/sdata/graphhopper/graph-cache.${next}

java -Xmx40g -jar graphhopper-web-11.0.jar import config-freemap.${next}.yml > /dev/null 2>&1

echo "Starting: $next"

java -Xmx40g -jar graphhopper-web-11.0.jar server config-freemap.${next}.yml > /dev/null 2>&1 &

echo $next > gh.active

mv europe-latest.osm.pbf.md5.candidate europe-latest.osm.pbf.md5

# wait one minute for GH to become active
echo Waiting

sleep 60

ps aux | grep "java.*graphhopper.*config-freemap\\.${active}\\.yml" | awk '{print $2}' | xargs --no-run-if-empty kill

rm -f ./graphhopper.freemap.sk
ln -s ./graphhopper.freemap.sk.${next} ./graphhopper.freemap.sk

echo Success

