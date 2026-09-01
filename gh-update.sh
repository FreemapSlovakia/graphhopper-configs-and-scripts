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

# Against deploy.sh — see take_update_lock in common.sh. Here rather than in
# common.sh's own body because it may need to mail, and the addresses only exist
# once the config above has been sourced.
take_update_lock

# A deadline rather than a number of tries, because a try is not a fixed length:
# while the port still refuses connections curl returns at once and an iteration
# is just the sleep, but once it is bound and slow the same iteration costs the
# 10 s timeout too. The 60 tries this carried for eight profiles were therefore
# anywhere from 5 to 15 minutes. 15 gives the first /route room to wait on a
# cold mmap of thirteen contractions and denser sampled geometry, and means one
# thing however it fails. Overshooting does not merely retry — it disables a
# freshly imported instance that was only slow, and halts the schedule. As in
# Photon, the cost of being generous is only how long a genuinely dead instance
# takes to be declared so.
wait_for_gh_ready() {
  local port="$1"
  local http_code deadline=$((SECONDS + 900))

  while [ "$SECONDS" -lt "$deadline" ]; do
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

# Where traffic actually goes rather than which units are enabled — see the
# same comment in photon-update.sh.
case "$(readlink ./graphhopper.freemap.sk 2>/dev/null || true)" in
  *graphhopper.freemap.sk.a) active="a" ;;
  *graphhopper.freemap.sk.b) active="b" ;;
  *) if systemctl is-enabled --quiet graphhopper@a; then active="a"
     elif systemctl is-enabled --quiet graphhopper@b; then active="b"
     else active="none"; fi ;;
esac
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
# Emptied rather than replaced — unlinking a directory needs write permission
# on its parent, which is not guaranteed for a data dir living outside our own.
# Sets data_dir.
resolve_data_dir "graph-cache.${next}"
cache_dir="$data_dir"
assert_instance_idle "graphhopper@${next}"

# The instance is idle and about to be rebuilt, so this is the moment the config
# and the models its graph will be built from get pinned to it for good. Both
# the import below and graphhopper@${next} then read the freeze, never the
# templates, so a pull landing later cannot leave the two disagreeing.
#
# Before the cache is cleared rather than after: if this fails there is no
# reason to have already destroyed the graph that was the thing to fall back on.
./freeze-config.sh "$next" \
  || hard_fail "Could not freeze the config for instance ${next}"

{ mkdir -p "$cache_dir" && find "$cache_dir" -mindepth 1 -delete; } \
  || hard_fail "Could not clear the graph cache at $cache_dir"

java -Xms2g -Xmx64g -jar graphhopper-web-11.0.jar import "run/instance.${next}/config.yml" \
  || hard_fail "GraphHopper import into instance ${next} failed"

echo "Starting: $next"
sudo -n /bin/systemctl enable --now graphhopper@${next} \
  || hard_fail "Could not start graphhopper@${next}"

echo "Polling: $next on localhost:${next_port}"
if ! wait_for_gh_ready "$next_port"; then
  sudo -n /bin/systemctl disable --now graphhopper@${next} || true
  hard_fail "New instance ${next} did not become ready on localhost:${next_port}"
fi

swap_symlink "./graphhopper.freemap.sk.${next}" ./graphhopper.freemap.sk \
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
