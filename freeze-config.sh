#!/bin/bash

# Freeze the config, the custom models and the jar an instance will run with.
#
# config-freemap.{a,b}.yml, custom_models/ and graphhopper-web-11.0.jar are
# templates. Nothing reads them directly: an instance reads run/instance.<i>/,
# written here.
#
# The reason is that GraphHopper validates, on every load, each profile's hash
# against the one stored in the graph — and that hash covers the custom model's
# contents, not just its file name (Profile.createContentString includes hints,
# and setCustomModel puts the parsed CustomModel there). A config that has moved
# on from the graph beside it therefore does not start. Three readers are
# separated in time: the import reads the config once at its start and runs for
# hours; the server reads it again when that import finishes; and, because the
# unit is Restart=on-failure, it reads it once more on every later restart, for
# as long as that graph is in service. A `git pull` can land in any of those
# gaps, so the templates cannot be what is read.
#
# Writing a freeze from today's templates is only sound at a moment when they
# are known to match the graph, and there are exactly two:
#
#   gh-update.sh, with no argument, just before it imports — the instance is
#   idle and its graph is about to be rebuilt from these very files;
#
#   deploy.sh, with --if-missing, just before it pulls — the templates have not
#   moved yet, so they are still what the live graphs were built from.
#
# Everywhere else the honest answer is to refuse. graphhopper@.service uses
# --check for that: a start with no freeze means the graph and the templates
# have already parted company, and inventing one there would assert something
# nothing has verified — every 30 seconds, for as long as the restart loop runs.
#
# The jar is frozen for the same reason and is not a lesser one. It decides what
# the encoded values in a graph *mean*: swapping a bit's meaning (GRAY for PURPLE
# in patch 0004) leaves a graph that loads and serves the wrong colour, and a jar
# that has lost an encoded value the frozen config names refuses to start at all.
# Installed by rename, so the running JVM keeps its own inode either way; copied
# rather than hardlinked here so the freeze holds even if that rule is broken.
#
# It is frozen under a fixed name, not the versioned one it is built as. The
# version belongs to the template; putting it in the frozen path would make it
# load-bearing in the unit's ExecStart and in the completeness test below, so a
# bump to 12.0 would leave every existing freeze holding a name nothing looks
# for — failing --check everywhere the moment the new script is pulled, which is
# exactly the migration this file already needs once.
#
# --if-missing never rewrites a freeze, only completes one. It runs against a
# live instance, whose graph can be older than today's templates, so replacing
# its config or its models there would assert a match nobody established. Only
# the create path, which runs when the instance is idle and about to be rebuilt,
# may write those.

set -euo pipefail

cd "$(dirname "$0")"

mode=create
case "${1:-}" in
  --if-missing)
    mode=if_missing
    shift
    ;;
  --check)
    mode=check
    shift
    ;;
esac

instance="${1:-}"
case "$instance" in
  a | b) ;;
  *)
    echo "usage: ${0##*/} [--if-missing|--check] <a|b>" >&2
    exit 2
    ;;
esac

dest="run/instance.${instance}"

# The template, carrying its build's version, and the fixed name it is frozen
# under. Only this line changes when the jar is bumped; the unit, the import and
# every existing freeze go on naming frozen_jar.
jar=graphhopper-web-11.0.jar
frozen_jar=graphhopper.jar

# Both halves, never just the config: a freeze whose models went missing — an
# interrupted cleanup, a stray rm in run/ — would otherwise pass for complete,
# and the instance would fail to start on a custom_models.directory pointing at
# nothing.
complete=0
if [[ -f "$dest/config.yml" && -d "$dest/custom_models" && -f "$dest/$frozen_jar" ]]; then
  complete=1

  # The GTFS feeds count as a third half, but only for a freeze that asks for
  # them. Read from the frozen config rather than the template on purpose: a
  # freeze written before public transport existed has no gtfs.file and must
  # still pass, because graphhopper@.service runs --check on every start and
  # tightening this unconditionally would strand every graph that predates it.
  if grep -q '^[[:space:]]*gtfs\.file:' "$dest/config.yml" && [ ! -d "$dest/gtfs" ]; then
    complete=0
  fi
fi

if [ "$mode" = check ]; then
  [ "$complete" = 1 ] && exit 0
  echo "no complete freeze at ${dest} — this graph and the templates have parted company." >&2
  echo "Import into this instance to rebuild both together, or restore the freeze from a backup." >&2
  exit 1
fi

if [ "$mode" = if_missing ]; then
  [ "$complete" = 1 ] && exit 0

  # A freeze with a config and models is somebody's graph, so it is completed in
  # place rather than rebuilt. The jar can be added honestly: before the freeze
  # held one the unit read the checkout's copy directly, so that is already what
  # this instance would restart into.
  if [[ -f "$dest/config.yml" && -d "$dest/custom_models" ]]; then
    if [ ! -f "$dest/$frozen_jar" ]; then
      if [ ! -f "$jar" ]; then
        echo "${jar} is not in this checkout, so the freeze at ${dest} cannot be completed" >&2
        exit 1
      fi
      cp "$jar" "$dest/.${frozen_jar}.new"
      mv -f "$dest/.${frozen_jar}.new" "$dest/$frozen_jar"
    fi

    # The feeds are the one thing that cannot be reconstructed here — run/gtfs/
    # holds whatever the last run fetched, not what this graph was built from.
    # Refusing beats both guessing and falling through to a rebuild, and the
    # next import into this instance writes a whole freeze anyway.
    if grep -q '^[[:space:]]*gtfs\.file:' "$dest/config.yml" && [ ! -d "$dest/gtfs" ]; then
      echo "the freeze at ${dest} names gtfs.file but has no gtfs/ — completing it here would" >&2
      echo "pin feeds this graph was not built from. Import into this instance to rebuild it." >&2
      exit 1
    fi

    exit 0
  fi
fi

# Said here rather than left to the import, which would fail some minutes later
# on whichever model file it happened to want first. The usual cause is
# custom_models/ never having been committed.
if [ ! -d custom_models ]; then
  echo "custom_models/ is not in this checkout — nothing to freeze for instance ${instance}" >&2
  echo "If it was never committed, commit it: the configs here read their models from it." >&2
  exit 1
fi

# Gitignored, unlike the two above, so a fresh checkout has none until one is
# built and installed. Said here for the same reason: otherwise the import runs
# for hours and the instance then fails to start on a missing ExecStart target.
if [ ! -f "$jar" ]; then
  echo "${jar} is not in this checkout — nothing to freeze for instance ${instance}" >&2
  echo "Build it and install it by rename; see 'Building the jar' in README.md." >&2
  exit 1
fi

# Assembled beside the destination and moved into place, so a freeze that dies
# half way through leaves the previous one whole rather than a truncated config
# or half a model directory. The swap itself is not atomic — rm then mv — but
# every caller has established that this instance is idle first, so there is
# nobody to read the gap.
staging="run/instance.${instance}.new"
rm -rf "$staging"
mkdir -p "$staging"

cp "config-freemap.${instance}.yml" "$staging/config.yml"
cp -r custom_models "$staging/custom_models"
cp "$jar" "$staging/$frozen_jar"

# The timetables this graph is about to be built from, pinned for a blunter
# reason than the config: run/gtfs/ is overwritten by every later run, so a
# config naming files there would, a day later, name files whose contents have
# moved on from the graph beside it. gh-update.sh fetches them just before
# calling this; deploy.sh's --if-missing path can run when none have been
# fetched yet, which is why finding none is not an error here.
if compgen -G 'run/gtfs/*.zip' > /dev/null; then
  mkdir -p "$staging/gtfs"
  cp run/gtfs/*.zip "$staging/gtfs/"
fi

rm -rf "$dest"
mv -T "$staging" "$dest"
