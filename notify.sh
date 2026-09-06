#!/bin/bash

# Sends a Mailgun email. Shared by the GraphHopper and Photon updaters.
#
#   notify.sh <subject>            body read from stdin; used by the update
#                                  scripts, which report their own results
#   notify.sh --abrupt <service>   backstop for an update service dying without
#                                  getting to report — driven by systemd's
#                                  $MONITOR_* variables, wired up as OnFailure=
#
# Expects MAILGUN_API_KEY, MAILGUN_DOMAIN and NOTIFY_EMAIL in the environment:
# exported by the update script, or via EnvironmentFile= in the abort unit.
# SERVICE names the schedule (the update scripts pass it; the abort units pass
# it as the --abrupt argument) and only shapes the From address. NOTIFY_FROM
# overrides that address outright, but it must be on MAILGUN_DOMAIN.

set -euo pipefail

cd "$(dirname "$0")"

host="$(hostname)"

case "${1:-}" in
  --abrupt)
    service="${2:-Update}"
    unit="${MONITOR_UNIT:-the update service}"

    # The update script mails its own failures, so anything that exited under
    # its own control has already been reported. Only deaths it could not
    # handle — OOM kill, SIGKILL, watchdog — are ours to announce.
    if [ "${MONITOR_SERVICE_RESULT:-}" = "exit-code" ]; then
      echo "${unit} exited with a status; it reported for itself"
      exit 0
    fi

    # reimport.sh --restart kills a running import on purpose, so that the next
    # one reads what was just deployed. This is where that lands, and measured
    # rather than assumed: an explicit `systemctl stop` really does record this
    # unit as failed and really does fire OnFailure=, and the script's own
    # reporting does not run at all. Observed on 2026-09-06 18:23, stopping a run that was mid-import: java was killed, bash
# went with it (code=killed, status=15/TERM), the EXIT trap printed ---END---
# but saw $? = 0 and so reported nothing, systemd recorded `Failed with result
# 'signal'` and fired OnFailure=, and the timer's already-queued next run began
# a second later and did nothing at all, because run/halted was by then there.
    #
    # So this is the check that matters, not a backstop for common.sh's. Halting
    # here would stop the schedule the operator is in the middle of restarting,
    # and the run reimport.sh starts a moment later would read run/halted and do
    # nothing — with nobody the wiser until the next day's data failed to appear.
    #
    # Matched by invocation rather than by age, so it can only excuse the one
    # run it was written for — never the fresh run started seconds later. The
    # marker is not removed here: the next update run sweeps it once it is old
    # enough that nothing can still want it.
    if [ -n "${MONITOR_INVOCATION_ID:-}" ] \
      && [ "$(cat run/aborting 2>/dev/null || true)" = "$MONITOR_INVOCATION_ID" ]; then
      echo "${unit} was stopped deliberately; not halting"
      exit 0
    fi

    # It never reached its own halt(), and an import killed once will likely be
    # killed again, so stop the schedule from here.
    { echo "Halted $(date -Is)"
      echo "Reason: ${unit} died (${MONITOR_SERVICE_RESULT:-unknown})"
      echo "To resume: rm $(pwd)/run/halted"
    } > run/halted

    subject="${service} update DIED on ${host}"
    body="${unit} terminated without reporting a result on ${host}
at $(date).

  result: ${MONITOR_SERVICE_RESULT:-unknown}
  code:   ${MONITOR_EXIT_CODE:-unknown}
  status: ${MONITOR_EXIT_STATUS:-unknown}

An out-of-memory kill during the import is the usual cause. Updates are HALTED
and the next runs will exit immediately. After fixing it:
  rm $(pwd)/run/halted

Check the log for details:
  journalctl -u ${unit}"
    ;;
  "" | -*)
    echo "usage: $0 <subject>            (body on stdin)" >&2
    echo "       $0 --abrupt <service>" >&2
    exit 1
    ;;
  *)
    service="${SERVICE:-Update}"
    subject="$1"
    body="$(cat)"
    ;;
esac

# Sender defaults to <service>-noreply@<the domain we are sending through>, so
# the two schedules can be filtered apart without anyone having to configure
# anything — and, more to the point, without a hand-written address drifting
# from MAILGUN_DOMAIN. A From on a domain Mailgun does not hold for us is
# rejected, and --fail-with-body turns that into a mail nobody receives.
#
# SERVICE is a display name for subject lines, so it has to be slugged before it
# can be a local part: a service called "Tile Server" would otherwise build an
# address with a space in it, and the rejected send would cost us exactly the
# notification we were trying to deliver.
slug="$(printf '%s' "$service" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
slug="${slug#-}"
slug="${slug%-}"
from="${NOTIFY_FROM:-${slug:-update}-noreply@${MAILGUN_DOMAIN}}"

to_args=()
IFS=',' read -ra emails <<< "${NOTIFY_EMAIL}"
for email in "${emails[@]}"; do
  to_args+=(-F "to=${email// /}")
done

# --fail-with-body so a rejected send shows up as a failure instead of silently
# succeeding; retry a couple of times for transient Mailgun errors.
curl -sS --fail-with-body --retry 3 --retry-connrefused --max-time 60 \
  --user "api:${MAILGUN_API_KEY}" \
  "https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages" \
  -F from="$from" \
  "${to_args[@]}" \
  -F subject="$subject" \
  -F text="$body"
