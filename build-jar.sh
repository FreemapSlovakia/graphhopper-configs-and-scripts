#!/bin/bash

# Build the jar this deployment runs: the 11.0 release, plus the two upstream
# commits it predates and the patches we carry on top.
#
# Run it on its own to check that a patch still applies and its tests still
# pass. That is safe at any moment — it only writes under build/, and nothing
# reads a jar from there. Installing what it built is deploy.sh --jar's job:
# the jar is a template like the config and the models, so it may only move
# under run/update.lock, in the gap between imports.
#
# Why the jar is not the official release, what each patch does, and what a jar
# silently missing one costs, is in README.md under "Building the jar". This is
# the executable half of that section; the reasoning stays there.
#
# stdout is the artifact's path and nothing else, so deploy.sh can install
# exactly what this produced. Everything else — maven, git, the checks below —
# goes to stderr.

set -euo pipefail

cd "$(dirname "$0")"

exec 3>&1 1>&2

UPSTREAM=https://github.com/graphhopper/graphhopper.git

# The release everything is built on, and the version in the artifact maven
# writes (the tag's pom says 11.0-SNAPSHOT).
BASE=11.0

# Upstream commits, cherry-picked only because they are unreleased. Each one
# leaves this list the moment a release carries it; neither is ours to keep.
CHERRY_PICKS=(
  "25903cd0c6cfd23e1e72da71900b26dc2cfc362f|#3183 sonny elevation provider"
  "75fb59df438bf6e536da51f4e453ad978149f355|#3235 skip elevation sampling on ferries"
)

# The name the template is installed under. freeze-config.sh names it too, and
# a version bump has to move both — so this is checked against that file rather
# than read from it, leaving the bump a deliberate edit in each place.
JAR=graphhopper-web-11.0.jar

# git cherry-pick and git am both write commits, and git refuses to write one
# for somebody it cannot name. The service user this runs as has no identity and
# has no business acquiring one, so the build brings its own: these commits live
# only under build/, are thrown away by the next run's `git clean`, and are never
# pushed anywhere. Only the committer is synthesised — the author comes from the
# commit being picked, or from the patch's own From: line.
export GIT_COMMITTER_NAME="graphhopper-configs-and-scripts"
export GIT_COMMITTER_EMAIL="build@localhost"

fail() {
  echo "$*"
  exit 1
}

# As deploy.sh does, and for the same reason: what this writes has to be
# replaceable by the updater later, and by deploy.sh --jar now.
owner="$(stat -c '%U' .)"
if [ "$(id -un)" != "$owner" ]; then
  fail "Run this as ${owner}, which owns the checkout: sudo -u ${owner} $0"
fi

for tool in git mvn javap unzip; do
  command -v "$tool" >/dev/null || fail "${tool} is not installed — see 'Building the jar' in README.md"
done

# A symlink to a volume with room, exactly as graph-cache.{a,b} are, and
# asserted for the same reason: readlink -f answers happily for a name that is
# not there, and the clone and maven's repository together are gigabytes that
# do not belong on whatever filesystem the checkout happens to sit on.
if [ ! -L build ] && [ ! -d build ]; then
  fail "build/ does not exist — create it as a symlink to a volume with a few GB free (a plain directory only if the build really belongs inside this checkout); do not mkdir it blindly"
fi
build_dir="$(readlink -f build)"
mkdir -p "$build_dir"

src="$build_dir/graphhopper"
# Maven's repository lands under the build volume too. The OS disk this
# checkout lives on is the one that fills.
m2="$build_dir/m2"

grep -qx "jar=${JAR}" freeze-config.sh \
  || fail "this builds ${JAR} but freeze-config.sh does not say jar=${JAR} — a version bump moves both or neither"

if [ ! -d "$src/.git" ]; then
  echo "Cloning ${UPSTREAM} into ${src}"
  git clone "$UPSTREAM" "$src"
fi

echo "Fetching upstream"
git -C "$src" fetch --tags --force origin

# Rebuilt from the tag every time rather than updated in place. A run that died
# half way through a cherry-pick or a `git am` leaves a tree that looks finished
# and is not, and the checks at the bottom would then be the only thing between
# that and a graph built by the wrong jar.
git -C "$src" am --abort 2>/dev/null || true
git -C "$src" cherry-pick --abort 2>/dev/null || true
git -C "$src" checkout --force --detach "$BASE"
git -C "$src" clean -qfdx

for pick in "${CHERRY_PICKS[@]}"; do
  echo "Cherry-picking ${pick%%|*} — ${pick#*|}"
  git -C "$src" cherry-pick "${pick%%|*}" \
    || fail "cherry-pick of ${pick%%|*} (${pick#*|}) failed — read the git output above rather than assuming it is a conflict"
done

# Everything in patches/, in name order, rather than a list to keep in step
# with the directory: adding 0006 should be a commit and nothing else.
shopt -s nullglob
patches=(patches/*.patch)
shopt -u nullglob
[ "${#patches[@]}" -gt 0 ] || fail "patches/ holds no *.patch — that cannot be right"

for patch in "${patches[@]}"; do
  echo "Applying ${patch}"
  git -C "$src" am < "$patch" \
    || fail "git am of ${patch} failed — read the git output above rather than assuming it is a conflict"
done

mvn=(mvn -B -f "$src/pom.xml" -Dmaven.repo.local="$m2")

# Nice'd for the same reason gh-update.service is: this can run while an import
# has the other 95 cores, and the import is the one with users waiting on it.
echo "Building"
nice -n 10 "${mvn[@]}" -DskipTests -pl web -am package \
  || fail "the build failed"

# Both patched classes carry tests, so they are run rather than trusted.
# -DfailIfNoTests=false is required, not optional: -am also runs the test phase
# in web-api, where the filter matches nothing and surefire would otherwise
# abort the reactor.
echo "Running the tests the patches carry"
nice -n 10 "${mvn[@]}" -pl core -am test -Dtest=SlopeCalculatorTest,OSMTrailColourParserTest -DfailIfNoTests=false \
  || fail "the core tests failed"
nice -n 10 "${mvn[@]}" -pl web -am test -Dtest=PtRouteResourceTest -DfailIfNoTests=false \
  || fail "the web tests failed"

built="$src/web/target/graphhopper-web-${BASE}-SNAPSHOT.jar"
[ -f "$built" ] || fail "the build produced no ${built}"

# Checked in the artifact rather than inferred from a clean build, because a
# jar quietly missing one of these is the expensive failure: the import does not
# complain, it aborts on `sonny`, fattens every ferry line with sampled points,
# writes the max_slope sentinel that once severed the stroller graph, or refuses
# to start at all because graph.encoded_values names colours it never heard of.
echo "Checking that everything landed"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Every check below reads a variable rather than the far end of a pipe. Both
# `grep -q` and an `awk` with an early `exit` close their pipe as soon as they
# have the answer, the `unzip` or `javap` upstream is killed by SIGPIPE for it,
# and pipefail then reports a check that passed as a check that failed. The jar
# was right and the test was wrong, which is the worst way round.
listing="$(unzip -l "$built")"

grep -q SonnyProvider <<<"$listing" \
  || fail "#3183 (sonny elevation provider) is not in the jar"

unzip -p "$built" com/graphhopper/reader/osm/OSMReader.class > "$tmp/OSMReader.class" \
  || fail "the jar has no com/graphhopper/reader/osm/OSMReader.class — has upstream moved it?"
dump="$(javap -p -c "$tmp/OSMReader.class")"
grep -q isFerry <<<"$(awk '/getLongEdgeSamplingDistance/{f=1} f{print} /EdgeSampling.sample/{if(f)exit}' <<<"$dump")" \
  || fail "#3235 (skip elevation sampling on ferries) is not in the jar"

unzip -p "$built" com/graphhopper/routing/util/SlopeCalculator.class > "$tmp/SlopeCalculator.class" \
  || fail "the jar has no com/graphhopper/routing/util/SlopeCalculator.class — has upstream moved it?"
dump="$(javap -p -c "$tmp/SlopeCalculator.class")"
found="$(grep -c maxSlopeEnc <<<"$(awk '/double 8.0d/{f=1} f&&/return/{exit} f' <<<"$dump")" || true)"
[ "$found" = 2 ] \
  || fail "patches/0003 (max_slope on short segments) is not in the jar: expected 2 maxSlopeEnc references on the short-edge path, found ${found}"

found="$(grep -c TrailColour <<<"$listing" || true)"
[ "$found" = 2 ] \
  || fail "patches/0004 (trail colours) is not in the jar: expected 2 TrailColour classes, found ${found}"

# javap -v, not -c: 0005's only trace in the bytecode is the @QueryParam
# annotation's value, which lives in the constant pool and the RuntimeVisible-
# Annotations attribute. -c prints neither, and would report this missing from
# a jar that has it.
unzip -p "$built" com/graphhopper/resources/PtRouteResource.class > "$tmp/PtRouteResource.class" \
  || fail "the jar has no com/graphhopper/resources/PtRouteResource.class — has upstream moved it?"
grep -q 'pt\.blocked_route_types' <<<"$(javap -v -p "$tmp/PtRouteResource.class")" \
  || fail "patches/0005 (pt.blocked_route_types) is not in the jar"

# Not a failure, and not something anything else will ever mention. We carry
# copies of two upstream pedestrian models; when upstream edits its own, the
# copies stop being a deliberate divergence and start being a stale one.
for model in foot hike; do
  if ! diff -q \
      <(sed -n '/^{/,$p' "$src/core/src/main/resources/com/graphhopper/custom_models/${model}.json") \
      <(sed -n '/^{/,$p' "custom_models/fm_${model}.json") >/dev/null; then
    echo "NOTE: upstream's ${model}.json has moved on from custom_models/fm_${model}.json — decide what to take, see 'Pedestrian Routing' in README.md"
  fi
done

# Staged under its installed name, so deploy.sh --jar has only to move it. Not
# installed here: that has to happen under run/update.lock.
artifact="$build_dir/$JAR"
cp "$built" "$artifact.new"
mv -f "$artifact.new" "$artifact"

echo "Built ${artifact}"
echo "$artifact" >&3
