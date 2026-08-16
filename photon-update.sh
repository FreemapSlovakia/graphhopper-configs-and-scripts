#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

SERVICE="Photon"
SERVICE_UNIT="photon-update.service"

# shellcheck source=common.sh
source ./common.sh

# Exported so ./notify.sh inherits MAILGUN_* and NOTIFY_EMAIL.
# shellcheck source=photon-update.conf
set -a
source ./photon-update.conf
set +a

# Opening a ~60G OpenSearch index takes appreciably longer than GraphHopper's
# mmap'd graph, so allow 10 minutes rather than 5. The only cost of being
# generous here is how long a genuinely dead instance takes to be declared so.
wait_for_photon_ready() {
  local port="$1"
  local body

  for _ in $(seq 1 120); do
    body="$(curl -sS --max-time 10 "http://127.0.0.1:${port}/api?q=bratislava&limit=1" || true)"

    # An index that is open but empty answers 200 with an empty feature list,
    # which would sail through an HTTP-status-only check and switch traffic to
    # a geocoder that finds nothing. Require an actual result.
    case "$body" in
      *'"coordinates"'*) return 0 ;;
    esac

    sleep 5
  done

  return 1
}

dump_file="run/$(basename "$PHOTON_DUMP_URL")"

# Sets md5_line and remote_md5.
fetch_md5 "${PHOTON_DUMP_URL}.md5"

if [ "$(stored_md5 run/photon.md5)" = "$remote_md5" ]; then
  echo "No update available"
  clear_failure_streak
  exit 0
fi

if systemctl is-enabled --quiet photon@a; then
  active="a"
elif systemctl is-enabled --quiet photon@b; then
  active="b"
else
  active="none"
fi
echo "Active: $active"

download_and_verify "$PHOTON_DUMP_URL" "$remote_md5" photon

if [[ "$active" == "a" ]]; then
  next="b"
  next_port=2323
else
  next="a"
  next_port=2322
fi

echo "Importing: $next"
# photon-data.{a,b} are symlinks to the real data dir; clear the target so the
# import starts from an empty index without clobbering the symlink. Photon
# creates photon_data/ underneath whatever -data-dir it is given.
data_dir="$(readlink -f "photon-data.${next}")"
{ rm -rf "$data_dir" && mkdir -p "$data_dir"; } \
  || hard_fail "Could not clear the Photon data dir at $data_dir"

# The dump is decompressed into the importer rather than onto disk: it expands
# several-fold and nothing else needs the plain JSONL. set -e is lifted so both
# ends of the pipe can be inspected — a zstd failure means the download rotted
# and is worth re-fetching, a java failure does not.
set +e
zstd --stdout -d "$dump_file" \
  | nice -n 10 java "-Xmx${PHOTON_IMPORT_HEAP}" -jar "$PHOTON_JAR" import \
      -import-file - \
      -data-dir "$data_dir" \
      -languages "$PHOTON_LANGUAGES"
import_rcs=("${PIPESTATUS[@]}")
set -e

if [ "${import_rcs[0]}" -ne 0 ]; then
  rm -f "$dump_file" run/photon-downloaded.md5
  soft_fail "Could not decompress $dump_file (zstd exit ${import_rcs[0]}) — discarded, re-downloading next run"
fi
if [ "${import_rcs[1]}" -ne 0 ]; then
  hard_fail "Photon import into instance ${next} failed (java exit ${import_rcs[1]})"
fi

echo "Starting: $next"
sudo -n /bin/systemctl enable --now photon@${next} \
  || hard_fail "Could not start photon@${next}"

echo "Polling: $next on localhost:${next_port}"
if ! wait_for_photon_ready "$next_port"; then
  sudo -n /bin/systemctl disable --now photon@${next} || true
  hard_fail "New instance ${next} did not return a geocoding result on localhost:${next_port}"
fi

rm -f ./photon-upstream.conf
ln -s ./photon-upstream.${next}.conf ./photon-upstream.conf \
  || hard_fail "Could not point ./photon-upstream.conf at instance ${next}"

sudo -n /bin/systemctl reload nginx || hard_fail "nginx reload failed"

# The vhost caches responses for 24h, so without this the old index keeps being
# served from cache long after the switchover.
if [ -n "${PHOTON_CACHE_DIR:-}" ] && [ -d "$PHOTON_CACHE_DIR" ]; then
  echo "Purging the nginx proxy cache at $PHOTON_CACHE_DIR"
  find "$PHOTON_CACHE_DIR" -mindepth 1 -delete \
    || echo "WARNING: could not fully purge $PHOTON_CACHE_DIR" >&2
fi

# Only now is this index really in service.
echo "$md5_line" > run/photon.md5

sudo -n /bin/systemctl disable --now photon@${active} || true

rm -f "$dump_file" run/photon-downloaded.md5
clear_failure_streak
reported=1
notify "${SERVICE} update succeeded on ${host}" <<EOF
Photon geocoding data was updated successfully on ${host} at $(date).

  instance:  ${active} -> ${next}
  dump:      ${md5_line}
  languages: ${PHOTON_LANGUAGES}
EOF
echo "Success"
