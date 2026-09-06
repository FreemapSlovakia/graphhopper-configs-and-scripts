#!/bin/bash

# Spend an import on something Geofabrik did not publish.
#
# The hourly run imports only when the extract's checksum has moved, so a
# config change, a new custom model or a new jar sits in the checkout until the
# mirror happens to publish. Every one of them needs an import to reach a
# graph: GraphHopper validates each profile's hash against the one stored in
# the graph, and the jar decides what the encoded values in that graph mean.
#
#   reimport.sh              queue one. If a run is already going it finishes
#                            first, and the forced import is the next one.
#   reimport.sh --restart    stop whatever is importing now and start over, so
#                            the import reads what was just deployed rather
#                            than what was there when it started.
#
# Either way the extract is downloaded again — the last successful run deleted
# it — so this costs the whole import, some fifteen hours, not the minutes the
# change took to write. Deploy first, force second: `deploy.sh --jar` and then
# this, never the other way round.

set -euo pipefail

cd "$(dirname "$0")"

restart=0
case "${1:-}" in
  --restart) restart=1 ;;
  "") ;;
  *) echo "usage: ${0##*/} [--restart]" >&2; exit 2 ;;
esac

# As deploy.sh does: run/force has to be writable by the updater afterwards,
# and the sudo rules below are granted to the service user, not to whoever is
# logged in.
owner="$(stat -c '%U' .)"
if [ "$(id -un)" != "$owner" ]; then
  echo "Run this as ${owner}, which owns the checkout: sudo -u ${owner} $0 $*" >&2
  exit 1
fi

# Starting the unit with this in place does nothing at all, silently, which is
# a confusing way to find out.
if [ -f run/halted ]; then
  echo "The schedule is halted, so a forced run would exit immediately:" >&2
  cat run/halted >&2
  echo "Fix the cause, rm run/halted, then run this again." >&2
  exit 1
fi

if [ "$restart" = 1 ]; then
  # A marker, not a bet on systemd's bookkeeping. A requested stop is normally
  # recorded as success, so OnFailure= never fires and this file is never read
  # — but if that assumption is wrong, gh-update-abort.service writes run/halted
  # and the deliberate restart would stop tomorrow's update too. notify.sh
  # --abrupt consumes it, and ages it out, so one left behind cannot go on
  # excusing real deaths.
  : > run/aborting

  echo "Stopping any running import"
  sudo -n /bin/systemctl stop gh-update.service

  # An import killed after its instance was started but before nginx moved
  # leaves that instance up on a half-built graph — and the next run refuses,
  # rightly, to clear a graph something is serving from. Retire it here.
  #
  # Which side is live comes from the nginx symlink, as everywhere else. If
  # there is none, nothing is touched: without it there is no way to tell the
  # half-built instance from the one answering, and guessing wrong stops the
  # service outright.
  live=""
  case "$(readlink ./graphhopper-upstream.conf 2>/dev/null || true)" in
    *graphhopper-upstream.a.conf) live=a ;;
    *graphhopper-upstream.b.conf) live=b ;;
  esac

  if [ -z "$live" ]; then
    echo "No graphhopper-upstream.conf symlink, so which instance is live is unknown —" >&2
    echo "not retiring anything. Check both instances by hand before the next import." >&2
  else
    for instance in a b; do
      if [ "$instance" = "$live" ]; then
        continue
      fi
      if systemctl is-active --quiet "graphhopper@${instance}" \
        || systemctl is-enabled --quiet "graphhopper@${instance}"; then
        echo "Retiring graphhopper@${instance}, which the killed import had started"
        sudo -n /bin/systemctl disable --now "graphhopper@${instance}"
      fi
    done
  fi
fi

# Read and cleared by gh-update.sh, which keeps it until an import has actually
# finished — so a forced run that retires on a mirror hiccup is retried by the
# next hourly one rather than quietly forgotten.
: > run/force

echo "Starting gh-update.service"
sudo -n /bin/systemctl start --no-block gh-update.service

rm -f run/aborting

echo
echo "Forced import queued. It re-downloads the extract, so expect the full run:"
echo "  journalctl -fu gh-update.service"
