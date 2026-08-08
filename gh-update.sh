#!/bin/bash

set -euo pipefail

# Exit code for recoverable problems (mirror 5xx, timeouts, truncated
# download). The EXIT trap leaves the hourly timer armed for these, so the next
# run just tries again. Any other non-zero exit is a hard failure: the timer is
# stopped so a broken state doesn't keep retrying until someone intervenes
# (re-arm with `systemctl start gh-update.timer`).
readonly EX_TEMPFAIL=75

# Recoverable failures stay silent (no email) until this many have happened in
# a row; then a notification is sent on every Nth consecutive one. Geofabrik
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

echo "---BEGIN---"

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne "$EX_TEMPFAIL" ]; then
    echo "Hard failure (exit $rc) — stopping the hourly timer"
    if ! sudo -n /bin/systemctl stop gh-update.timer; then
      # Don't let this pass silently: the whole point of the hard-failure path
      # is that a broken state stops re-running every hour.
      local warning="WARNING: could not stop gh-update.timer — it will keep retrying hourly"
      echo "$warning" >&2
      echo "$warning" >> "${error_file:-/dev/null}" 2>/dev/null || true
      echo "$warning" >> run/last-error 2>/dev/null || true
    fi
  fi
  echo "---END---"
}
# Concurrent runs are already prevented by systemd: the timer won't start
# gh-update.service while a previous run is still active.
trap on_exit EXIT

cd "$(dirname "$0")"

mkdir -p run

# Where this run reports its outcome to gh-notify.sh.
#
# It has to be keyed on the invocation, not a fixed name: when the timer fires
# while a run is busy — which any import longer than an hour guarantees —
# systemd leaves a start job queued and releases it the instant this run exits,
# concurrently with the OnSuccess=/OnFailure= mailer. A shared run/result is
# overwritten by that next run before the mailer can read it, and the
# notification is silently lost. systemd hands the mailer this same ID in
# $MONITOR_INVOCATION_ID.
run_id="${INVOCATION_ID:-manual}"
result_file="run/result.${run_id}"
error_file="run/error.${run_id}"

# Backstop only: every invocation's files are consumed by its mailer, since
# OnSuccess= and OnFailure= between them cover every way a run can end.
find run -maxdepth 1 -type f \( -name 'result.*' -o -name 'error.*' \) \
  -mtime +7 -delete 2>/dev/null || true

# The unsuffixed copies exist so the last outcome can be read by hand; the
# mailer prefers the per-invocation ones. Note the startup default below is
# written *only* to this run's private file, so that a finishing run's outcome
# outlives the start of the next one.
record_result() {
  echo "$1" > "$result_file"
  echo "$1" > run/result
}

record_error() {
  echo "$*" > "$error_file"
  echo "$*" > run/last-error
}

echo "skipped" > "$result_file"

# Never let a previous run's message end up in this run's failure email.
rm -f "$error_file" run/last-error

clear_failure_state() {
  echo 0 > run/fail-streak
  rm -f "$error_file" run/last-error
}

# Unrecoverable: report, stop the timer (via the EXIT trap), email.
hard_fail() {
  echo "$*" >&2
  record_error "$*"
  record_result failed
  exit 1
}

# Recoverable: report and get out, leaving the timer armed for the next hour.
# Exits 0 (silent) unless the same thing keeps happening.
soft_fail() {
  local streak
  echo "$*" >&2
  record_error "$*"
  record_result retry

  streak="$(cat run/fail-streak 2>/dev/null || true)"
  [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
  streak=$((streak + 1))
  echo "$streak" > run/fail-streak

  echo "Recoverable failure #${streak} — timer stays armed, retrying next hour"
  if [ $((streak % NOTIFY_AFTER_FAILURES)) -eq 0 ]; then
    exit "$EX_TEMPFAIL"
  fi
  exit 0
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

# shellcheck source=gh-update.conf
source ./gh-update.conf

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
  record_result skipped
  clear_failure_state
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
clear_failure_state
record_result updated
echo "Success"
