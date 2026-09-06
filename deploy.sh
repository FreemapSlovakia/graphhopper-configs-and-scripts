#!/bin/bash

# Update the checkout without ever crossing a running import.
#
# Run it whenever; it blocks until it is safe and needs no watching. Two things
# make an unguarded `git pull` unsafe here:
#
#   - the config and the custom models it would move are validated against the
#     graph an instance has loaded, so moving them under a live instance means
#     that instance cannot restart — see freeze-config.sh;
#   - bash reads a script as it executes it, so replacing an updater while a run
#     is in flight can leave that run parsing the tail of a different file.
#
# Both are solved by holding the same lock the updaters hold for the whole of a
# run, and by freezing what is running now before the templates move.

set -euo pipefail

# The body is a function so bash has parsed the whole script before the pull
# below can rewrite it — the same self-modification hazard the header describes,
# which this script would otherwise be the last one exposed to. Bash returns to
# a byte offset after each command of a seekable script, so a pull that changes
# this file's length would leave whatever follows executing from the wrong place
# in the new content.
main() {
  cd "$(dirname "$0")"

  # No sudo anywhere below — but everything here writes into the checkout, and
  # the updater has to be able to replace it later as the service user. Run as
  # anyone else and it leaves a freeze that user cannot overwrite; run as root
  # and it leaves one nothing else can.
  local owner
  owner="$(stat -c '%U' .)"
  if [ "$(id -un)" != "$owner" ]; then
    echo "Run this as ${owner}, which owns the checkout: sudo -u ${owner} $0" >&2
    exit 1
  fi

  # The repository is checked out once per service, each ignoring the other's
  # files, and which one this is decides what has to be frozen and which lock
  # matters. Told apart by the conf, the same way the two updaters are.
  local service
  if [ -f gh-update.conf ]; then
    service=graphhopper
  elif [ -f photon-update.conf ]; then
    service=photon
  else
    echo "Neither gh-update.conf nor photon-update.conf is here — is this a service checkout?" >&2
    exit 1
  fi

  mkdir -p run

  # Blocking, not `flock -n`. An import takes hours and the timer starts the
  # next one shortly after it ends, so a deploy that gave up on a busy lock
  # would almost never get in. Waiting for the gap is the whole point.
  exec 9>run/update.lock
  echo "Waiting for any running ${service} update to finish"
  flock 9
  echo "Lock acquired"

  # Capture what the live instances are running on, before the pull moves the
  # templates out from under them. This is the only moment outside an import at
  # which a freeze can honestly be written, which is why it is here and not left
  # to the unit — see freeze-config.sh. Creates only what is missing, so it is
  # the bootstrap on the first deployment and a no-op on every one after.
  #
  # GraphHopper only, and not because Photon reads nothing from here — it does,
  # photon@.service takes EnvironmentFile=photon-instance.%i.conf and re-reads
  # it on every restart. The criterion is narrower: GraphHopper validates its
  # config against the graph it loads and refuses to start on a mismatch,
  # whereas Photon checks nothing against its index, so a conf that has moved on
  # costs it a stale port rather than a failure to come back.
  #
  # The live side only. The idle one's graph was built at some earlier
  # generation of these templates — possibly several deploys back — so writing
  # today's for it would assert a match nobody established, and --check would
  # then vouch for it. It needs nothing from here anyway: gh-update.sh re-freezes
  # that side from scratch before every import.
  #
  # Which side is live comes from the nginx symlink, the same question the
  # updaters ask and for the same stated reason — where traffic actually goes,
  # not which units are enabled. Unit state would be the wrong predicate twice
  # over: an instance reads as inactive through every RestartSec hold, and an
  # instance that is down *because* its freeze is missing is exactly the one
  # this can still repair, while the templates ahead of the pull still match it.
  local live=""
  if [ "$service" = graphhopper ]; then
    case "$(readlink ./graphhopper-upstream.conf 2>/dev/null || true)" in
      *graphhopper-upstream.a.conf) live=a ;;
      *graphhopper-upstream.b.conf) live=b ;;
    esac
    if [ -n "$live" ]; then
      ./freeze-config.sh --if-missing "$live"
    else
      echo "No graphhopper-upstream.conf symlink — nothing is live, so nothing to freeze." >&2
    fi
  fi

  git pull --ff-only

  # Said definitively rather than left as "if it changed": an instance still on
  # the old ExecStart reads the templates, and once the next import moves those
  # past the graph it has loaded, it cannot come back from its next restart.
  local unit="${service}@.service" installed="/etc/systemd/system/${service}@.service"
  if ! cmp -s "$unit" "$installed"; then
    echo
    echo "${unit} differs from ${installed} — install it, as root:"
    echo "  install -m644 $(pwd)/${unit} ${installed} && systemctl daemon-reload"
    exit 1
  fi

  echo
  if [ -n "$live" ]; then
    echo "Checkout updated. graphhopper@${live} is untouched, on its own freeze at"
    echo "run/instance.${live}/, and the next import will pick this up."
  else
    echo "Checkout updated. Nothing was frozen — the next import will pick this up."
  fi
}

main "$@"; exit $?
