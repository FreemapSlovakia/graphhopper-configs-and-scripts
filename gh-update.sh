#!/bin/bash

set -e

echo "---BEGIN---"
trap 'echo "---END---"' EXIT

cd "$(dirname "$0")"

# shellcheck source=gh-update.conf
source ./gh-update.conf

mkdir -p run

# Default result; overwritten to "updated" only after a successful update.
# Read by gh-notify.sh to suppress the success email when there was no update.
echo "skipped" > run/result

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

# GEOFABRIK_URL is set in gh-update.conf
pbf_file="run/$(basename "$GEOFABRIK_URL")"

remote_md5="$(wget -q -O - "${GEOFABRIK_URL}.md5")"

if [ -f run/osm.md5 ] && [ "$(cat run/osm.md5)" = "$remote_md5" ]; then
  echo "No update available"
  exit 0
fi

if systemctl is-enabled --quiet graphhopper@a; then
  active="a"
elif systemctl is-enabled --quiet graphhopper@b; then
  active="b"
else
  active="none"
fi
echo "Active: $active"

if [ -f "$pbf_file" ] && [ -f run/downloaded.md5 ] && [ "$(cat run/downloaded.md5)" = "$remote_md5" ]; then
  echo "Already downloaded, reusing $pbf_file"
else
  echo "Downloading"
  rm -f "$pbf_file"
  wget -nv "$GEOFABRIK_URL" -P run
  echo "$remote_md5" > run/downloaded.md5
fi

echo "Extracting"
osmium extract --set-bounds -p limit.geojson "$pbf_file" -o run/extract.pbf

if [[ "$active" == "a" ]]; then
  next="b"
  next_port=9989
else
  next="a"
  next_port=8989
fi

echo "Importing: $next"
rm -rf /fm/sdata/graphhopper/graph-cache.${next} && mkdir -p /fm/sdata/graphhopper/graph-cache.${next}
nice java -Xms1g -Xmx28g -jar graphhopper-web-11.0.jar import config-freemap.${next}.yml

echo "Starting: $next"
sudo -n /bin/systemctl enable --now graphhopper@${next}

echo "Polling: $next on localhost:${next_port}"
if ! wait_for_gh_ready "$next_port"; then
  echo "New instance ${next} did not become ready on localhost:${next_port}"
  sudo -n /bin/systemctl disable --now graphhopper@${next} || true
  exit 1
fi

echo "$remote_md5" > run/osm.md5

rm -f ./graphhopper.freemap.sk
ln -s ./graphhopper.freemap.sk.${next} ./graphhopper.freemap.sk

sudo -n /bin/systemctl reload nginx
sudo -n /bin/systemctl disable --now graphhopper@${active} || true

rm -f "$pbf_file" run/downloaded.md5 run/extract.pbf
echo "updated" > run/result
echo "Success"
