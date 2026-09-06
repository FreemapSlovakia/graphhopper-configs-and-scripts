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

# An import Geofabrik did not ask for. The hourly run only imports when the
# extract's checksum has moved, so a new config, a new custom model or a new jar
# would otherwise sit in the checkout until the mirror happens to publish — and
# none of the three reaches a graph without an import.
#
# reimport.sh writes the file rather than passing the flag, so a forced run
# still happens inside gh-update.service, with its journal, its Nice= and its
# OnFailure=. --force is for driving this script by hand.
#
# Taken by rename, into run/forcing, and only that is cleared at the end. Two
# files rather than one because both of these have to hold:
#
#   a request made *during* a run must survive it — reimport.sh can be run while
#   an import is already going, and that import is building a graph from what
#   was there before, so the request belongs to the next one. Clearing run/force
#   at the end of this run would silently swallow it;
#
#   a request must survive a run that failed. A mirror hiccup means the import
#   that was asked for did not happen, so run/forcing stays and the next hourly
#   run picks it up rather than quietly going back to sleep.
force=0
case "${1:-}" in
  --force) force=1 ;;
  "") ;;
  *) echo "usage: ${0##*/} [--force]" >&2; exit 2 ;;
esac
if [ -f run/force ]; then
  force=1
  mv -f run/force run/forcing
fi
if [ -f run/forcing ]; then
  force=1
fi

# Against deploy.sh — see take_update_lock in common.sh. Here rather than in
# common.sh's own body because it may need to mail, and the addresses only exist
# once the config above has been sourced.
take_update_lock

# The one /route both readiness checks send, so what nginx is asked for is
# exactly what the instance itself was proved able to answer. Two points a
# kilometre apart in Šariš: far enough to need the graph, close enough that a
# healthy instance answers in milliseconds.
PROBE_ROUTE='{"profile":"car","points":[[20.778408050524682,49.005743088335926],[20.795849427570825,49.00523635421394]]}'

# The public name, which is also the vhost's file name. Only ever used with
# curl --resolve, so the post-switch check reaches this box's own nginx and
# cannot be answered by anything sitting in front of it.
SITE_HOST="graphhopper.freemap.sk"

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
      --data-raw "$PROBE_ROUTE" \
      || true)"

    [ "$http_code" = "200" ] && return 0

    sleep 5
  done

  return 1
}

# The last check of a switchover, and the only one that exercises the path a
# user takes: TLS, the vhost, the include, the proxy_pass. Everything before it
# proves the new instance is healthy on its own port, which is a different
# claim from nginx sending anything there.
#
# It asserts *which* side answered rather than merely that something did,
# because pointing nginx at the instance that is about to be retired is exactly
# the mistake worth catching, and that mistake answers 200 right up until the
# old side is stopped. On 2026-09-06 it did: the b fragment carried a's port,
# the flip sent every request to a, and `disable --now graphhopper@a` two
# seconds later took routing down for an hour and three quarters. The header
# comes from the fragment nginx has just started including, so it can only say
# `b` if the b fragment is the one in force.
#
# Retried for a minute rather than asked once: a reload is graceful, and there
# is no reason to roll a good switchover back over a worker that had not
# finished picking up the new config.
#
# -k because what this asserts is nginx's plumbing, not Certbot's. An expired
# certificate is a real outage, but it is one the old instance shares, has its
# own monitoring, and cannot be repaired by rolling this switchover back — so it
# should not be the thing that halts an import that otherwise succeeded.
verify_through_nginx() { # expected instance
  local want="$1" out deadline=$((SECONDS + 60))

  while [ "$SECONDS" -lt "$deadline" ]; do
    out="$(curl -sSk --max-time 15 -o /dev/null -D - -w 'http_code=%{http_code}\n' \
      --resolve "${SITE_HOST}:443:127.0.0.1" \
      "https://${SITE_HOST}/route" \
      -H 'Content-Type: application/json' \
      --data-raw "$PROBE_ROUTE" \
      || true)"

    # -qi because HTTP/2 lowercases header names, and the trailing
    # [[:space:]]* eats the CR that -D keeps.
    if grep -q '^http_code=200$' <<<"$out" \
       && grep -qi "^x-gh-instance:[[:space:]]*${want}[[:space:]]*$" <<<"$out"; then
      return 0
    fi

    sleep 5
  done

  return 1
}

# The GTFS feeds that give /route-pt its timetables, as `name|url`. The name is
# the file the feed is stored under, so renaming one re-downloads it rather than
# updating it in place.
#
# Here rather than in gh-update.conf because these are project data, not
# deployment secrets: a change to them belongs in the checkout, reviewable and
# self-deploying, next to limit.geojson and the custom models.
#
# Refreshed only on runs that have new OSM data, since the run exits above this
# point when there is none. Geofabrik publishes daily and neither feed changes
# more than weekly, so a timetable here is never more than a day behind its
# source -- which is the whole reason public transport can live on this graph
# rather than an instance of its own.
GTFS_FEEDS=(
  # Železničná spoločnosť Slovensko, every Slovak train. Published through the
  # national open data catalogue: the gtfs.zip under zsr.sk that most feed
  # directories still list now redirects to a landing page and carries nothing.
  "zssk|https://data.slovensko.sk/download?id=b2441eda-421e-4a13-981b-71c0309e7bfe"
  # Dopravný podnik Bratislava, CC BY 4.0 -- freemap.sk must credit it. This is
  # the ArcGIS item behind data.bratislava.sk's "Cestovné poriadky MHD vo
  # formáte GTFS"; the opendata.bratislava.sk URLs that Transitland and the
  # Mobility Database still publish are dead.
  "dpb|https://www.arcgis.com/sharing/rest/content/items/aba12fd2cbac4843bc7406151bc66106/data"
  # Dopravný podnik mesta Prešov, CC BY 4.0, published for them by R&G PLUS.
  # Same ArcGIS pattern as Bratislava. Its calendar runs about three months at a
  # time, against DPB's four and ZSSK's twelve, so this is the feed that goes
  # quiet first if a publisher is ever late renewing -- the import stays green
  # either way, because a lapsed calendar is not an error, it is simply a feed
  # with no departures left.
  "presov|https://www.arcgis.com/sharing/rest/content/items/f1033ca6c2f4461d9aba285e1c7cb079/data"
)

# A feed is usable only if it is an intact zip carrying the files GraphHopper's
# GTFS reader needs. Checked on arrival because the alternative is finding out
# hours later, from a stack trace, in the middle of an import.
gtfs_zip_ok() { # file
  local file="$1" listing name
  unzip -tqq "$file" >/dev/null 2>&1 || return 1
  listing="$(unzip -Z1 "$file" 2>/dev/null)" || return 1
  for name in agency.txt routes.txt trips.txt stops.txt stop_times.txt; do
    grep -qxF "$name" <<<"$listing" || return 1
  done
  # GTFS requires at least one of the two calendars; both of ours ship both.
  grep -qxE 'calendar(_dates)?\.txt' <<<"$listing"
}

# The last good copy outlives a failed refresh. A transit operator's web server
# having a bad morning is not a reason to skip a day of European routing, and a
# timetable a week stale still routes; only having no copy at all is fatal,
# because then there is nothing for the import to read.
fetch_gtfs() { # name, url
  local name="$1" url="$2"
  local dest="run/gtfs/${name}.zip" tmp="run/gtfs/.${name}.new"

  mkdir -p run/gtfs
  rm -f "$tmp"

  if curl -fsSL --max-time 600 -o "$tmp" "$url" && gtfs_zip_ok "$tmp"; then
    mv -f "$tmp" "$dest"
    echo "GTFS ${name}: refreshed, $(stat -c %s "$dest") bytes"
    return 0
  fi

  rm -f "$tmp"
  if [ -f "$dest" ]; then
    echo "GTFS ${name}: refresh failed, keeping the copy from $(date -r "$dest" '+%Y-%m-%d %H:%M')" >&2
    return 0
  fi

  hard_fail "GTFS feed ${name} could not be fetched from ${url} and there is no previous copy at ${dest}"
}

# GEOFABRIK_URL is set in gh-update.conf
pbf_file="run/$(basename "$GEOFABRIK_URL")"

# Sets md5_line and remote_md5.
fetch_md5 "${GEOFABRIK_URL}.md5"

# run/osm.md5 holds the full remote line; compare only the hash.
trigger="new extract"
if [ "$(stored_md5 run/osm.md5)" = "$remote_md5" ]; then
  if [ "$force" = 0 ]; then
    echo "No update available"
    clear_failure_streak
    exit 0
  fi
  # The extract is downloaded again below regardless: the last successful run
  # deleted it, and the import has to read something.
  trigger="forced re-import, no new extract"
  echo "No new extract on the mirror, but a re-import was asked for"
fi

# Where traffic actually goes rather than which units are enabled — see the
# same comment in photon-update.sh.
case "$(readlink ./graphhopper-upstream.conf 2>/dev/null || true)" in
  *graphhopper-upstream.a.conf) active="a" ;;
  *graphhopper-upstream.b.conf) active="b" ;;
  *) if systemctl is-enabled --quiet graphhopper@a; then active="a"
     elif systemctl is-enabled --quiet graphhopper@b; then active="b"
     else active="none"; fi ;;
esac
echo "Active: $active"

download_and_verify "$GEOFABRIK_URL" "$remote_md5" osm

echo "Extracting"
osmium extract --set-bounds -p limit.geojson "$pbf_file" -o run/extract.pbf --overwrite \
  || hard_fail "osmium extract failed on $pbf_file"

# Before the freeze that copies these, and well before the graph cache is
# cleared: a feed that cannot be fetched at all has to stop the run while the
# idle instance still has the graph it was going to fall back on.
echo "Fetching GTFS feeds"
for feed in "${GTFS_FEEDS[@]}"; do
  fetch_gtfs "${feed%%|*}" "${feed#*|}"
done

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

# The instance is idle and about to be rebuilt, so this is the moment the config,
# the models and the jar its graph will be built from get pinned to it for good.
# Both the import below and graphhopper@${next} then read the freeze, never the
# templates, so a pull landing later cannot leave the two disagreeing.
#
# Before the cache is cleared rather than after: if this fails there is no
# reason to have already destroyed the graph that was the thing to fall back on.
./freeze-config.sh "$next" \
  || hard_fail "Could not freeze the config for instance ${next}"

{ mkdir -p "$cache_dir" && find "$cache_dir" -mindepth 1 -delete; } \
  || hard_fail "Could not clear the graph cache at $cache_dir"

# The jar just frozen, so the graph is written by the one that will serve it —
# a jar installed while this runs belongs to the next import, not to this graph.
# The frozen copy carries no version in its name, so this line survives a bump.
java -Xms2g -Xmx64g -jar "run/instance.${next}/graphhopper.jar" \
  import "run/instance.${next}/config.yml" \
  || hard_fail "GraphHopper import into instance ${next} failed"

echo "Starting: $next"
sudo -n /bin/systemctl enable --now graphhopper@${next} \
  || hard_fail "Could not start graphhopper@${next}"

echo "Polling: $next on localhost:${next_port}"
if ! wait_for_gh_ready "$next_port"; then
  sudo -n /bin/systemctl disable --now graphhopper@${next} || true
  hard_fail "New instance ${next} did not become ready on localhost:${next_port}"
fi

# Before anything moves, because here a mismatch costs only the run — past the
# flip below it costs live traffic. The fragment is one line and nginx cannot
# tell a stale one from a fresh one; the port it names has to be the port
# instance ${next} just answered on, and nothing else in the pipeline ties
# those two together.
#
# This and verify_through_nginx catch the same fault from opposite ends and
# neither subsumes the other: a fragment overwritten wholesale by a copy of the
# other side fails here, while one whose port was corrected but whose header
# was not fails there.
grep -q "127\.0\.0\.1:${next_port}/" "./graphhopper-upstream.${next}.conf" \
  || hard_fail "./graphhopper-upstream.${next}.conf does not proxy to 127.0.0.1:${next_port}, which is where instance ${next} just answered — refusing to switch traffic to it"

swap_symlink "./graphhopper-upstream.${next}.conf" ./graphhopper-upstream.conf \
  || hard_fail "Could not point ./graphhopper-upstream.conf at instance ${next}"

sudo -n /bin/systemctl reload nginx || hard_fail "nginx reload failed"

echo "Verifying: ${SITE_HOST} serves instance ${next}"
if ! verify_through_nginx "$next"; then
  # The old instance is still running — retiring it is the next step, not this
  # one — so putting the symlink back is a real recovery and not a gesture.
  rolled_back=""
  if [ "$active" = a ] || [ "$active" = b ]; then
    if swap_symlink "./graphhopper-upstream.${active}.conf" ./graphhopper-upstream.conf \
       && sudo -n /bin/systemctl reload nginx; then
      rolled_back=" Traffic was rolled back to instance ${active}, which is still up."
    else
      rolled_back=" Rolling back to instance ${active} failed too, so routing is down."
    fi
  fi
  hard_fail "nginx did not answer as instance ${next} after the switchover, even though ${next} is healthy on localhost:${next_port} — check graphhopper-upstream.${next}.conf and the vhost.${rolled_back}"
fi

# Only now is this extract really in service, and only now is that a claim
# something checked end to end. Recording it any earlier would make the next
# run say "No update available" and skip a switchover that never actually
# happened.
echo "$md5_line" > run/osm.md5

sudo -n /bin/systemctl disable --now graphhopper@${active} || true

rm -f "$pbf_file" run/osm-downloaded.md5 run/extract.pbf run/forcing
clear_failure_streak
reported=1
notify "${SERVICE} update succeeded on ${host}" <<EOF
GraphHopper OSM data was updated successfully on ${host} at $(date).

  instance: ${active} -> ${next}
  data:     ${md5_line}
  trigger:  ${trigger}
EOF
echo "Success"
