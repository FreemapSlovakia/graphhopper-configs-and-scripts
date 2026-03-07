#!/bin/bash

# Sends a Mailgun email notification for gh-update.service results.
# Called by gh-update-notify@.service with argument "success" or "failure".
# Expects MAILGUN_API_KEY, MAILGUN_DOMAIN, NOTIFY_EMAIL in the environment
# (set via EnvironmentFile in gh-update-notify@.service).

set -euo pipefail

cd "$(dirname "$0")"

case "${1:-}" in
  success)
    result="$(cat run/result 2>/dev/null || echo skipped)"
    if [ "$result" != "updated" ]; then
      exit 0  # no update was performed; skip email
    fi
    subject="GraphHopper update succeeded on $(hostname)"
    body="GraphHopper OSM data was updated successfully on $(hostname) at $(date)."
    ;;
  failure)
    subject="GraphHopper update FAILED on $(hostname)"
    body="The GraphHopper OSM update has FAILED on $(hostname) at $(date).

Check the log for details:
  journalctl -u gh-update.service

To retry the update manually after fixing the issue:
  systemctl start gh-update.service"
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

curl -s --user "api:${MAILGUN_API_KEY}" \
  "https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages" \
  -F from="graphhopper-noreply@${MAILGUN_DOMAIN}" \
  "${to_args[@]}" \
  -F subject="$subject" \
  -F text="$body"
