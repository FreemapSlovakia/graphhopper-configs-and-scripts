#!/bin/bash

set -euo pipefail

# Consecutive recoverable failures before one is worth an email. Geofabrik
# hiccups usually clear within an hour or two — a whole day of them does not.
readonly NOTIFY_AFTER_FAILURES=6

# Survive slow mirrors and the 5xx pages geofabrik's download proxy serves
# while it rotates files.
readonly WGET_RETRY_OPTS=(
  --tries=5
  --waitretry=30
  --timeout=60
  --retry-connrefused
  --retry-on-host-error
  --retry-on-http-error=408,429,500,502,503,504
)

cd "$(dirname "$0")"

mkdir -p run

echo "---BEGIN---"

# Exported so gh-notify.sh inherits MAILGUN_* and NOTIFY_EMAIL.
# shellcheck source=gh-update.conf
set -a
source ./gh-update.conf
set +a

host="$(hostname)"

# This run sends its own mail, from the point of failure, where the reason is
# still in a variable. Nothing is handed to another process through the
# filesystem — that is what used to lose notifications, when the next run
# overwrote the outcome before the mailer had read it.
reported=0

notify() { # subject in $1, body on stdin
  ./gh-notify.sh "$1" || echo "WARNING: could not send notification: $1" >&2
}

# Stop the schedule until a human has looked. A marker file rather than
# stopping the timer: it needs no privileges and, unlike a stopped timer unit,
# it survives a reboot.
halt() {
  { echo "Halted $(date -Is)"
    echo "Reason: $*"
    echo "To resume: rm $(pwd)/run/halted"
  } > run/halted
}

# Unrecoverable: halt the schedule and say so.
hard_fail() {
  echo "$*" >&2
  halt "$*"
  notify "GraphHopper update FAILED on ${host}" <<EOF
The GraphHopper OSM update has FAILED on ${host} at $(date).

  $*

Updates are HALTED and the next runs will exit immediately. After fixing it:
  rm $(pwd)/run/halted

Check the log for details:
  journalctl -u gh-update.service
EOF
  reported=1
  exit 1
}

# Recoverable: leave the schedule alone and let the next run try again. Stays
# quiet unless the same thing keeps happening.
soft_fail() {
  local streak
  streak="$(cat run/fail-streak 2>/dev/null || true)"
  [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
  streak=$((streak + 1))
  echo "$streak" > run/fail-streak

  echo "$*" >&2
  echo "Recoverable failure #${streak} — the next run will retry"

  if [ $((streak % NOTIFY_AFTER_FAILURES)) -eq 0 ]; then
    notify "GraphHopper update still failing on ${host} (${streak} in a row)" <<EOF
The GraphHopper OSM update has hit ${streak} recoverable failures in a row on
${host}, most recently at $(date).

  $*

This looks like network/mirror trouble, which usually clears on its own. The
schedule is untouched and the next run will try again. No action needed unless
this keeps arriving.

Check the log for details:
  journalctl -u gh-update.service
EOF
  fi

  reported=1
  exit 0
}

on_exit() {
  local rc=$?
  # A death that got past hard_fail/soft_fail — set -e tripping somewhere with
  # no message of its own. Report it rather than let it vanish.
  if [ "$rc" -ne 0 ] && [ "$reported" -eq 0 ]; then
    halt "exited unexpectedly with status $rc"
    notify "GraphHopper update FAILED on ${host}" <<EOF
The GraphHopper OSM update on ${host} exited unexpectedly with status ${rc} at
$(date), without reporting a reason.

Updates are HALTED and the next runs will exit immediately. After fixing it:
  rm $(pwd)/run/halted

Check the log for details:
  journalctl -u gh-update.service
EOF
  fi
  echo "---END---"
}
# Concurrent runs are already prevented by systemd: the timer won't start
# gh-update.service while a previous run is still active.
trap on_exit EXIT

if [ -f run/halted ]; then
  echo "Halted by an earlier failure — doing nothing:"
  cat run/halted
  exit 0
fi

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

md5_of() {
  local sum
  sum="$(md5sum < "$1")"
  echo "${sum%% *}"
}

# First field of a stored checksum file, empty if it doesn't exist. Tolerates
# both bare hashes and full "<hash>  <filename>" lines.
stored_md5() {
  awk '{print $1}' "$1" 2>/dev/null || true
}

# wget exit 3 is a local file I/O error (no space left, bad permissions on
# run/). Waiting an hour won't fix that, and retrying a ~35G download every
# hour on a full disk is worse than useless, so take the hard path.
wget_failed() {
  local rc="$1"
  shift
  if [ "$rc" -eq 3 ]; then
    hard_fail "$* (wget exit 3: local file I/O error — check free space and permissions on run/)"
  fi
  soft_fail "$* (wget exit $rc)"
}

# GEOFABRIK_URL is set in gh-update.conf
pbf_file="run/$(basename "$GEOFABRIK_URL")"

md5_line="$(wget "${WGET_RETRY_OPTS[@]}" -q -O - "${GEOFABRIK_URL}.md5")" \
  || wget_failed $? "Could not fetch ${GEOFABRIK_URL}.md5"

# The .md5 file is "<hash>  <dated-filename>"; a proxy error page or an empty
# body would sail through wget's exit code check, so validate the shape.
remote_md5="${md5_line%% *}"
[[ "$remote_md5" =~ ^[0-9a-f]{32}$ ]] \
  || soft_fail "Unexpected content in ${GEOFABRIK_URL}.md5: ${md5_line:0:200}"

# run/osm.md5 holds the full remote line; compare only the hash.
if [ "$(stored_md5 run/osm.md5)" = "$remote_md5" ]; then
  echo "No update available"
  echo 0 > run/fail-streak
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

if [ -f "$pbf_file" ] && [ "$(stored_md5 run/downloaded.md5)" = "$remote_md5" ]; then
  echo "Already downloaded and verified, reusing $pbf_file"
else
  # Resume a partial download only when it belongs to this same remote file,
  # otherwise wget -c would happily append to the leftovers of an older one.
  if [ -f "$pbf_file" ] && [ "$(stored_md5 run/downloading.md5)" = "$remote_md5" ]; then
    echo "Resuming download of $pbf_file"
  else
    rm -f "$pbf_file" run/downloaded.md5
    echo "$remote_md5" > run/downloading.md5
    echo "Downloading $GEOFABRIK_URL"
  fi

  # Keep whatever arrived on failure — the next run resumes from there.
  wget "${WGET_RETRY_OPTS[@]}" -c -nv "$GEOFABRIK_URL" -P run \
    || wget_failed $? "Download of $GEOFABRIK_URL failed; will resume next run"

  echo "Verifying download"
  actual_md5="$(md5_of "$pbf_file")"
  if [ "$actual_md5" != "$remote_md5" ]; then
    rm -f "$pbf_file" run/downloading.md5
    # Re-downloading tens of gigabytes every hour is expensive, so give a bad
    # download exactly one retry: if the same remote checksum fails to match
    # twice, the mirror (or the local disk) is broken, not unlucky.
    if [ "$(stored_md5 run/mismatch.md5)" = "$remote_md5" ]; then
      rm -f run/mismatch.md5
      hard_fail "Checksum mismatch for $pbf_file twice in a row (expected $remote_md5, got $actual_md5) — not retrying"
    fi
    echo "$remote_md5" > run/mismatch.md5
    soft_fail "Checksum mismatch for $pbf_file (expected $remote_md5, got $actual_md5); discarded, re-downloading once"
  fi

  rm -f run/mismatch.md5
  mv run/downloading.md5 run/downloaded.md5
fi

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

rm -f "$pbf_file" run/downloaded.md5 run/extract.pbf
echo 0 > run/fail-streak
reported=1
notify "GraphHopper update succeeded on ${host}" <<EOF
GraphHopper OSM data was updated successfully on ${host} at $(date).

  instance: ${active} -> ${next}
  data:     ${md5_line}
EOF
echo "Success"
