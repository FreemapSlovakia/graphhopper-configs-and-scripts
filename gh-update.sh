#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

SERVICE="GraphHopper"
SERVICE_UNIT="gh-update.service"

# shellcheck source=common.sh
source ./common.sh

# Exported so ./notify.sh inherits MAILGUN_* and NOTIFY_EMAIL.
# shellcheck source=gh-update.conf
set -a
source ./gh-update.conf
set +a

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

# Sets md5_line and remote_md5.
fetch_md5 "${GEOFABRIK_URL}.md5"

# run/osm.md5 holds the full remote line; compare only the hash.
if [ "$(stored_md5 run/osm.md5)" = "$remote_md5" ]; then
  echo "No update available"
  clear_failure_streak
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

download_and_verify "$GEOFABRIK_URL" "$remote_md5" osm

echo "Extracting"
osmium extract --set-bounds -p limit.geojson "$pbf_file" -o run/extract.pbf --overwrite \
  || hard_fail "osmium extract failed on $pbf_file"

if [[ "$active" == "a" ]]; then
  next="b"
  next_port=9989
else
  next="a"
  next_port=8989
fi

echo "Importing: $next"
# graph-cache.{a,b} are symlinks to the real data dir; clear the target so
# GraphHopper imports into a clean cache without clobbering the symlink.
cache_dir="$(readlink -f "graph-cache.${next}")"
{ rm -rf "$cache_dir" && mkdir -p "$cache_dir"; } \
  || hard_fail "Could not clear the graph cache at $cache_dir"
java -Xms2g -Xmx64g -jar graphhopper-web-11.0.jar import config-freemap.${next}.yml \
  || hard_fail "GraphHopper import into instance ${next} failed"

echo "Starting: $next"
sudo -n /bin/systemctl enable --now graphhopper@${next} \
  || hard_fail "Could not start graphhopper@${next}"

echo "Polling: $next on localhost:${next_port}"
if ! wait_for_gh_ready "$next_port"; then
  sudo -n /bin/systemctl disable --now graphhopper@${next} || true
  hard_fail "New instance ${next} did not become ready on localhost:${next_port}"
fi

rm -f ./graphhopper.freemap.sk
ln -s ./graphhopper.freemap.sk.${next} ./graphhopper.freemap.sk \
  || hard_fail "Could not point ./graphhopper.freemap.sk at instance ${next}"

sudo -n /bin/systemctl reload nginx || hard_fail "nginx reload failed"

# Only now is this extract really in service. Recording it any earlier would
# make the next run say "No update available" and skip a switchover that never
# actually happened.
echo "$md5_line" > run/osm.md5

sudo -n /bin/systemctl disable --now graphhopper@${active} || true

rm -f "$pbf_file" run/osm-downloaded.md5 run/extract.pbf
clear_failure_streak
reported=1
notify "${SERVICE} update succeeded on ${host}" <<EOF
GraphHopper OSM data was updated successfully on ${host} at $(date).

  instance: ${active} -> ${next}
  data:     ${md5_line}
EOF
echo "Success"
