# Shared scaffolding for the update scripts. Not executable on its own.
#
# Before sourcing this, a caller must:
#   cd "$(dirname "$0")"     so run/ and ./notify.sh resolve
#   SERVICE=<name>           human name for mail subjects, e.g. "GraphHopper"
#   SERVICE_UNIT=<unit>      systemd unit, quoted in mail bodies
#
# and afterwards source its own config for MAILGUN_* / NOTIFY_EMAIL, with
# `set -a` so ./notify.sh inherits them.
#
# This file then provides notify/halt/hard_fail/soft_fail/wget_failed and the
# checksum helpers, installs the EXIT trap, and returns early — by exiting the
# caller — if the schedule is halted.

# Consecutive recoverable failures before one is worth an email. Mirror hiccups
# usually clear within an hour or two — a whole day of them does not.
readonly NOTIFY_AFTER_FAILURES=6

# Survive slow mirrors and the 5xx pages the download proxies serve while they
# rotate files.
readonly WGET_RETRY_OPTS=(
  --tries=5
  --waitretry=30
  --timeout=60
  --retry-connrefused
  --retry-on-host-error
  --retry-on-http-error=408,429,500,502,503,504
)

mkdir -p run

echo "---BEGIN---"

host="$(hostname)"

# Each run sends its own mail, from the point of failure, where the reason is
# still in a variable. Nothing is handed to another process through the
# filesystem — that is what used to lose notifications, when the next run
# overwrote the outcome before the mailer had read it.
reported=0

notify() { # subject in $1, body on stdin
  ./notify.sh "$1" || echo "WARNING: could not send notification: $1" >&2
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
  notify "${SERVICE} update FAILED on ${host}" <<EOF
The ${SERVICE} update has FAILED on ${host} at $(date).

  $*

Updates are HALTED and the next runs will exit immediately. After fixing it:
  rm $(pwd)/run/halted

Check the log for details:
  journalctl -u ${SERVICE_UNIT}
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
    notify "${SERVICE} update still failing on ${host} (${streak} in a row)" <<EOF
The ${SERVICE} update has hit ${streak} recoverable failures in a row on
${host}, most recently at $(date).

  $*

This looks like network/mirror trouble, which usually clears on its own. The
schedule is untouched and the next run will try again. No action needed unless
this keeps arriving.

Check the log for details:
  journalctl -u ${SERVICE_UNIT}
EOF
  fi

  reported=1
  exit 0
}

clear_failure_streak() {
  echo 0 > run/fail-streak
}

on_exit() {
  local rc=$?
  # A death that got past hard_fail/soft_fail — set -e tripping somewhere with
  # no message of its own. Report it rather than let it vanish.
  if [ "$rc" -ne 0 ] && [ "$reported" -eq 0 ]; then
    halt "exited unexpectedly with status $rc"
    notify "${SERVICE} update FAILED on ${host}" <<EOF
The ${SERVICE} update on ${host} exited unexpectedly with status ${rc} at
$(date), without reporting a reason.

Updates are HALTED and the next runs will exit immediately. After fixing it:
  rm $(pwd)/run/halted

Check the log for details:
  journalctl -u ${SERVICE_UNIT}
EOF
  fi
  echo "---END---"
}
# Concurrent runs are already prevented by systemd: the timer won't start the
# update service while a previous run is still active.
trap on_exit EXIT

if [ -f run/halted ]; then
  echo "Halted by an earlier failure — doing nothing:"
  cat run/halted
  exit 0
fi

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

# Fetch a "<hash>  <filename>" checksum file and set md5_line / remote_md5. A
# proxy error page or an empty body would sail through wget's exit code check,
# so the shape is validated too.
#
# Sets globals rather than echoing on purpose: as a $(...) helper, the
# soft_fail/hard_fail inside it would run in a subshell, where exit ends only
# the subshell and the run carries on — past a checksum it never managed to
# read. Nothing below may call the *_fail functions from a subshell.
fetch_md5() { # url
  local url="$1"
  md5_line="$(wget "${WGET_RETRY_OPTS[@]}" -q -O - "$url")" \
    || wget_failed $? "Could not fetch $url"
  remote_md5="${md5_line%% *}"
  [[ "$remote_md5" =~ ^[0-9a-f]{32}$ ]] \
    || soft_fail "Unexpected content in ${url}: ${md5_line:0:200}"
}

# wget exit 3 is a local file I/O error (no space left, bad permissions on
# run/). Waiting for the next run won't fix that, and re-fetching tens of
# gigabytes onto a full disk is worse than useless, so take the hard path.
wget_failed() {
  local rc="$1"
  shift
  if [ "$rc" -eq 3 ]; then
    hard_fail "$* (wget exit 3: local file I/O error — check free space and permissions on run/)"
  fi
  soft_fail "$* (wget exit $rc)"
}

# Resolve an a/b data symlink to the real directory. `readlink -f` returns 0 and
# echoes the path even when the link does not exist, which would quietly send a
# multi-gigabyte import onto whatever filesystem the checkout lives on, so
# require an actual symlink.
# Sets data_dir. Not a $(...) helper, for the same reason as fetch_md5: the
# hard_fail below has to run in the caller's shell.
resolve_data_dir() { # symlink
  [ -L "$1" ] || hard_fail "$1 is not a symlink — refusing to import into an unknown location"
  data_dir="$(readlink -f "$1")"
}

# Never clear the data an instance is currently serving from. Reachable when a
# previous run died between the nginx flip and retiring the old side, leaving
# both instances enabled.
assert_instance_idle() { # unit
  if systemctl is-active --quiet "$1"; then
    hard_fail "$1 is running — refusing to clear the data it is serving from"
  fi
}

# Repoint a symlink atomically. nginx can reload at any moment — certbot, or the
# other updater finishing — and a missing include target fails the whole config.
swap_symlink() { # target, linkname
  ln -sfn "$1" "$2.new" && mv -Tf "$2.new" "$2"
}

# Download to run/, resuming only a partial file that belongs to this same
# remote object, and verify it. The target is always run/<basename of the URL>,
# because wget -P is used rather than -O: -O with -c does not resume reliably.
download_and_verify() { # url, expected-hash, statefile-prefix
  local url="$1" want="$2" pfx="$3" file actual
  file="run/$(basename "$url")"

  if [ -f "$file" ] && [ "$(stored_md5 "run/${pfx}-downloaded.md5")" = "$want" ]; then
    echo "Already downloaded and verified, reusing $file"
    return 0
  fi

  # Resume a partial download only when it belongs to this same remote file,
  # otherwise wget -c would happily append to the leftovers of an older one.
  if [ -f "$file" ] && [ "$(stored_md5 "run/${pfx}-downloading.md5")" = "$want" ]; then
    echo "Resuming download of $file"
  else
    rm -f "$file" "run/${pfx}-downloaded.md5"
    echo "$want" > "run/${pfx}-downloading.md5"
    echo "Downloading $url"
  fi

  # Keep whatever arrived on failure — the next run resumes from there.
  wget "${WGET_RETRY_OPTS[@]}" -c -nv "$url" -P run \
    || wget_failed $? "Download of $url failed; will resume next run"

  echo "Verifying download"
  actual="$(md5_of "$file")"
  if [ "$actual" != "$want" ]; then
    rm -f "$file" "run/${pfx}-downloading.md5"
    # Re-downloading tens of gigabytes every run is expensive, so give a bad
    # download exactly one retry: if the same remote checksum fails to match
    # twice, the mirror (or the local disk) is broken, not unlucky.
    if [ "$(stored_md5 "run/${pfx}-mismatch.md5")" = "$want" ]; then
      rm -f "run/${pfx}-mismatch.md5"
      hard_fail "Checksum mismatch for $file twice in a row (expected $want, got $actual) — not retrying"
    fi
    echo "$want" > "run/${pfx}-mismatch.md5"
    soft_fail "Checksum mismatch for $file (expected $want, got $actual); discarded, re-downloading once"
  fi

  rm -f "run/${pfx}-mismatch.md5"
  mv "run/${pfx}-downloading.md5" "run/${pfx}-downloaded.md5"
}
