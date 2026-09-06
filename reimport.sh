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
  # Name the run about to be killed, so that run — and only that run — can tell
  # its own death from a real one. `systemctl stop` SIGTERMs the whole cgroup,
  # and what happens next was measured, not assumed: killed mid-import, bash
  # goes down with its java and reports nothing, systemd records the unit failed
  # with result 'signal', and gh-update-abort.service halts the schedule through
  # notify.sh. Killed anywhere else, gh-update.sh's own `|| hard_fail` or EXIT
  # trap gets there first instead. Either way run/halted appears, and the run
  # started at the bottom of this script would read it and do nothing at all —
  # so common.sh and notify.sh both check this marker.
  #
  # Written before the stop, because afterwards there is no invocation left to
  # ask about. Nothing running means nothing to excuse, and nothing to write —
  # and InvocationID outlives the run it names, so asking without checking the
  # state first would write a marker for a run that ended hours ago.
  #
  # Not `is-active`: gh-update.service is Type=oneshot with no RemainAfterExit,
  # so while its ExecStart runs the unit sits in `activating`, which is-active
  # reports as false. Same trap the migration block in README.md warns about.
  case "$(systemctl show -p ActiveState --value gh-update.service 2>/dev/null || true)" in
    inactive | failed | "") ;;
    *)
      invocation="$(systemctl show -p InvocationID --value gh-update.service 2>/dev/null || true)"
      if [ -n "$invocation" ]; then
        echo "$invocation" > run/aborting
      fi
      ;;
  esac

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

# run/aborting is deliberately left where it is. Removing it here would race the
# OnFailure= job that may still be about to read it, and it can excuse nothing
# but the invocation it names in any case; the next update run sweeps it once it
# is old enough that nothing can still want it.

echo
echo "Forced import queued. It re-downloads the extract, so expect the full run:"
echo "  journalctl -fu gh-update.service"
