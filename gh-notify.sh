#!/bin/bash

# Sends a Mailgun email notification for gh-update.service results.
# Called by gh-update-notify@.service with argument "success" or "failure".
# Expects MAILGUN_API_KEY, MAILGUN_DOMAIN, NOTIFY_EMAIL in the environment
# (set via EnvironmentFile in gh-update-notify@.service).

set -euo pipefail

cd "$(dirname "$0")"

host="$(hostname)"
result="$(cat run/result 2>/dev/null || true)"
reason="$(cat run/last-error 2>/dev/null || true)"
[ -n "$reason" ] || reason="(no message recorded — see the journal)"

case "${1:-}" in
  success)
    if [ "$result" != "updated" ]; then
      exit 0  # no update was performed; skip email
    fi
    subject="GraphHopper update succeeded on ${host}"
    body="GraphHopper OSM data was updated successfully on ${host} at $(date)."
    ;;
  failure)
    # gh-update.sh writes "retry" only on the recoverable path. Anything else,
    # including a run that died before it could classify itself, is a hard
    # failure — the safe way round to be wrong.
    if systemctl is-active --quiet gh-update.timer; then
      timer_state="The hourly timer is still armed."
    else
      timer_state="The hourly timer has been STOPPED — no further updates will
run until it is re-armed (note it comes back by itself after a reboot)."
    fi

    if [ "$result" = "retry" ]; then
      streak="$(cat run/fail-streak 2>/dev/null || echo '?')"
      subject="GraphHopper update still failing on ${host} (${streak} in a row)"
      body="The GraphHopper OSM update has hit ${streak} recoverable failures in a row on
${host}, most recently at $(date).

Last error:
  ${reason}

This looks like network/mirror trouble, which usually clears on its own.
${timer_state}

Check the log for details:
  journalctl -u gh-update.service"
    else
      subject="GraphHopper update FAILED on ${host}"
      body="The GraphHopper OSM update has FAILED on ${host} at $(date).

Last error:
  ${reason}

${timer_state}

Check the log for details:
  journalctl -u gh-update.service

To retry the update after fixing the issue:
  systemctl reset-failed gh-update.service
  systemctl start gh-update.timer
  systemctl start --no-block gh-update.service"
    fi
    ;;
  *)
    echo "Usage: $0 success|failure" >&2
    exit 1
    ;;
esac

to_args=()
IFS=',' read -ra emails <<< "${NOTIFY_EMAIL}"
for email in "${emails[@]}"; do
  to_args+=(-F "to=${email// /}")
done

# --fail-with-body so a rejected send shows up as a failed notify unit instead
# of silently succeeding; retry a couple of times for transient Mailgun errors.
curl -sS --fail-with-body --retry 3 --retry-connrefused --max-time 60 \
  --user "api:${MAILGUN_API_KEY}" \
  "https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages" \
  -F from="graphhopper-noreply@${MAILGUN_DOMAIN}" \
  "${to_args[@]}" \
  -F subject="$subject" \
  -F text="$body"
