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
from="${NOTIFY_FROM:-$(printf '%s' "$service" | tr '[:upper:]' '[:lower:]')-noreply@${MAILGUN_DOMAIN}}"

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
