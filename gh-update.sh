#!/bin/bash

set -e

echo "---BEGIN---"
trap 'echo "---END---"' EXIT

cd "$(dirname "$0")"

# Default result; overwritten to "updated" only after a successful update.
# Read by gh-notify.sh to suppress the success email when there was no update.
echo "skipped" > gh-update-result

wait_for_gh_ready() {
  local port="$1"
  local http_code

  for _ in $(seq 1 60); do
    http_code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/route" \
      -H 'Content-Type: application/json' \
      --data-raw '{"profile":"car","points":[[20.778408050524682,49.005743088335926],[20.795849427570825,49.00523635421394]]}' \
      || true)"

    [ "$http_code" = "200" ] && return 0

    sleep 5
  done

  return 1
}

remote_md5="$(wget -q -O - https://download.geofabrik.de/europe-latest.osm.pbf.md5)"

if [ -f europe-latest.osm.pbf.md5 ] && [ "$(cat europe-latest.osm.pbf.md5)" = "$remote_md5" ]; then
  echo "No update available"
  exit 0
fi

active=$(test -f gh.active && cat gh.active || echo 'none')
echo "Active: $active"

echo "Downloading"
rm -f tmp/europe-latest.osm.pbf tmp/extract.pbf
wget -nv https://download.geofabrik.de/europe-latest.osm.pbf -P tmp

echo "Extracting"
osmium extract --set-bounds -p limit.geojson tmp/europe-latest.osm.pbf -o tmp/extract.pbf
rm tmp/europe-latest.osm.pbf

if [[ "$active" == "a" ]]; then
  next="b"
  next_port=9989
else
  next="a"
  next_port=8989
fi

echo "Importing: $next"
rm -rf /fm/sdata/graphhopper/graph-cache.${next} && mkdir -p /fm/sdata/graphhopper/graph-cache.${next}
nice java -Xms1g -Xmx28g -jar graphhopper-web-11.0.jar import config-freemap.${next}.yml > /dev/null 2>&1

echo "Starting: $next"
sudo -n /bin/systemctl start graphhopper@${next}

echo "Polling: $next on localhost:${next_port}"
if ! wait_for_gh_ready "$next_port"; then
  echo "New instance ${next} did not become ready on localhost:${next_port}"
  sudo -n /bin/systemctl stop graphhopper@${next} || true
  exit 1
fi

echo "$next" > gh.active
printf '%s\n' "$remote_md5" > europe-latest.osm.pbf.md5

rm -f ./graphhopper.freemap.sk
ln -s ./graphhopper.freemap.sk.${next} ./graphhopper.freemap.sk

sudo -n /bin/systemctl reload nginx
sudo -n /bin/systemctl stop graphhopper@${active} || true

echo "updated" > gh-update-result
echo "Success"
