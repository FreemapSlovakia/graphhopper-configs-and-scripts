#!/bin/bash

# Sends a Mailgun email.
#
#   gh-notify.sh <subject>   body read from stdin; used by gh-update.sh, which
#                            reports its own results
#   gh-notify.sh --abrupt    backstop for gh-update.service dying without
#                            getting to report — driven by systemd's $MONITOR_*
#                            variables, wired up as OnFailure=
#
# Expects MAILGUN_API_KEY, MAILGUN_DOMAIN and NOTIFY_EMAIL in the environment:
# exported by gh-update.sh, or via EnvironmentFile= in gh-update-abort.service.

set -euo pipefail

cd "$(dirname "$0")"

host="$(hostname)"

case "${1:-}" in
  --abrupt)
    # gh-update.sh mails its own failures, so anything that exited under its
    # own control has already been reported. Only deaths it could not handle —
    # OOM kill, SIGKILL, watchdog — are ours to announce.
    if [ "${MONITOR_SERVICE_RESULT:-}" = "exit-code" ]; then
      echo "gh-update.service exited with a status; it reported for itself"
      exit 0
    fi

    # It never reached its own halt(), and an import killed once will likely be
    # killed again, so stop the schedule from here.
    { echo "Halted $(date -Is)"
      echo "Reason: ${MONITOR_UNIT:-gh-update.service} died (${MONITOR_SERVICE_RESULT:-unknown})"
      echo "To resume: rm $(pwd)/run/halted"
    } > run/halted

    subject="GraphHopper update DIED on ${host}"
    body="${MONITOR_UNIT:-gh-update.service} terminated without reporting a result on ${host}
at $(date).

  result: ${MONITOR_SERVICE_RESULT:-unknown}
  code:   ${MONITOR_EXIT_CODE:-unknown}
  status: ${MONITOR_EXIT_STATUS:-unknown}

An out-of-memory kill during the import is the usual cause. Updates are HALTED
and the next runs will exit immediately. After fixing it:
  rm $(pwd)/run/halted

Check the log for details:
  journalctl -u gh-update.service"
    ;;
  "" | -*)
    echo "usage: $0 <subject>    (body on stdin)" >&2
    echo "       $0 --abrupt" >&2
    exit 1
    ;;
  *)
    subject="$1"
    body="$(cat)"
    ;;
esac

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
  -F from="graphhopper-noreply@${MAILGUN_DOMAIN}" \
  "${to_args[@]}" \
  -F subject="$subject" \
  -F text="$body"
