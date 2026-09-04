# Freemap Routing & Geocoding Ops

Scripts that keep the **GraphHopper** routing data and the **Photon** geocoding
index up to date, using systemd timers and services.

Both follow the same shape — check a remote checksum, download and verify,
import into the idle instance, health-check it, flip nginx, retire the old one
— so the machinery is shared and only the service-specific steps differ.

## Scripts

| Script             | Role                                                                   |
| ------------------ | ---------------------------------------------------------------------- |
| `common.sh`        | Shared scaffolding: failure classification, halting, retries, downloads |
| `gh-update.sh`     | GraphHopper: OSM extract → import → switchover                          |
| `photon-update.sh` | Photon: JSONL dump → import → switchover                                |
| `freeze-config.sh` | Pins a config and custom models to the graph being built                |
| `deploy.sh`        | `git pull` that waits for the gap between imports                       |
| `notify.sh`        | Sends one Mailgun email (subject + body on stdin, or `--abrupt`)        |

The repository is checked out **twice** on the server, at `/opt/graphhopper`
and `/opt/photon`. Each checkout keeps its own `run/` state and its own
`*-update.conf` and ignores the other service's files. That is what lets both
share one `notify.sh` and one `common.sh` rather than carrying divergent copies
of the same failure handling.

State kept between runs in `run/`, where `<x>` is `osm` or `photon`:

| File                  | Meaning                                                     |
| --------------------- | ----------------------------------------------------------- |
| `osm.md5`             | Checksum line of the currently imported OSM extract          |
| `photon.md5`          | Checksum line of the currently imported Photon dump          |
| `<x>-downloading.md5` | Checksum the partially downloaded file is expected to have   |
| `<x>-downloaded.md5`  | Checksum of a fully downloaded and verified file             |
| `<x>-mismatch.md5`    | Checksum that already failed verification once               |
| `fail-streak`         | Consecutive recoverable failures                             |
| `halted`              | Present = every run exits immediately until it is removed    |
| `instance.{a,b}/`     | The config and custom models that instance's graph was built from |
| `update.lock`         | Held by a run, and by `deploy.sh` while it pulls              |

## Photon

Photon is fed from komoot's JSONL dump rather than the prebuilt index tarball,
because the index has to carry our own language list
(`sk,cs,en,de,fr,it,hu,pl,sl,hr,sr,uk,ro,nl,es,pt`) and the prebuilt one carries
komoot's. The tradeoff is roughly 7 hours of import per update.

- Source: `download1.graphhopper.com/public/europe/photon-dump-europe-1.0-latest.jsonl.zst` (~13 GB).
  The top-level `photon-db-latest.tar.bz2` on that server is stale (built
  2025-07-20); only the versioned paths under `europe/` are maintained.
- Rebuilt upstream roughly weekly, so `photon-update.timer` runs **daily**, not hourly.
- The dump is downloaded and verified, then streamed through `zstd -d` into the
  importer; the plain JSONL is never written to disk.
- Instances `photon@a` (port 2322) and `photon@b` (2323), data in
  `photon-data.{a,b}` — symlinks to `/fm/data4/photon-data/{a,b}`, mirroring
  how `graph-cache.{a,b}` point into `/fm/data4/graphhopper-data`. The parent
  is owned by `freemap` so the import can create and remove the instance
  directories itself; the scripts also empty rather than replace them, so they
  work even where the parent is not writable.
- The vhost `include`s `photon-upstream.conf`, a symlink flipped between
  `photon-upstream.{a,b}.conf`. Only the `proxy_pass` line differs, so the TLS
  config cannot drift between the two sides.
- The health check requires an actual geocoding result: an index that is open
  but empty answers 200 with no features, and a status-only check would switch
  traffic to a geocoder that finds nothing.
- Responses are **not** cached in nginx, so the switchover takes effect on the
  reload and an uptime check reaches the real backend. See the comment in
  `photon.freemap.sk` for the measurements behind that.
- The jar version appears in two places that have to agree: `ExecStart` in
  `photon@.service` and `PHOTON_JAR` in `photon-update.conf`.
- `nginx-photon.conf` is installed by hand at `/etc/nginx/conf.d/` and is not
  managed by this checkout. It holds the `limit_req_zone` the vhost depends on,
  so the vhost cannot be deployed anywhere that file is missing.

## Systemd Units

| Unit                          | Purpose                                             |
| ----------------------------- | --------------------------------------------------- |
| `graphhopper@.service`        | GraphHopper routing server (instances `a` and `b`)  |
| `gh-update.service`           | Oneshot update job                                  |
| `gh-update.timer`             | Triggers `gh-update.service` hourly                 |
| `gh-update-abort.service`     | `OnFailure=` backstop for an update that was killed |
| `photon@.service`             | Photon geocoder (instances `a` and `b`)             |
| `photon-update.service`       | Oneshot update job                                  |
| `photon-update.timer`         | Triggers `photon-update.service` daily              |
| `photon-update-abort.service` | `OnFailure=` backstop for an update that was killed |

The update script sends its own mail, at the point of failure, where the reason
is still in a variable. Nothing is handed to another process through the
filesystem — that is what used to lose notifications: when the timer fires while
a run is busy (which any import longer than an hour guarantees), systemd
releases the queued next run at the same instant as the mailer, and the next
run's startup would overwrite the outcome before the mailer had read it.

`gh-update-abort.service` covers the one case the script cannot report for
itself: being killed outright, typically by the OOM killer during the import. It
fires on `OnFailure=` but stays quiet whenever `$MONITOR_SERVICE_RESULT` is
`exit-code`, since that means the script was alive to mail for itself.

## What Happens

1. Timer triggers `gh-update.service` every hour.
2. If `run/halted` exists, the run exits immediately.
3. Script checks if new OSM data is available; exits silently if not.
4. If yes, downloads the extract (resuming a partial one) and verifies its checksum.
5. Freezes `config-freemap.<i>.yml` and `custom_models/` into `run/instance.<i>/`.
6. Imports the data into the inactive instance (`a` or `b`), from that freeze.
7. Starts the new instance via systemd and polls until it is healthy.
8. Switches nginx to the new instance and stops the old one.
9. Emails the result.

## Deploying a config change

Edit `config-freemap.{a,b}.yml` or `custom_models/` here, push, and on the
server:

```bash
sudo -u freemap /opt/graphhopper/deploy.sh
```

Any time — it waits for the gap between imports by itself and needs no
watching. The change takes effect on the next import, one instance at a time,
and the live instance is not touched.

It uses no sudo of its own, but it must run as the user that owns the checkout,
because the updater has to be able to replace what it writes; it refuses to
start otherwise. The one `sudo` above prompts once, before the wait, so the run
can be left in `tmux` without a second prompt appearing hours later. Logging in
as `freemap` does as well, if going through sudo is not wanted.

The same script serves `/opt/photon`. It tells the two checkouts apart by which
`*-update.conf` sits beside it, takes the per-instance freezes only for
GraphHopper, and refuses to finish quietly if the pull left `<service>@.service`
differing from the copy installed under `/etc/systemd/system` — an instance left
on the old `ExecStart` still reads the templates, which is the one failure all
of this exists to prevent.

Do not `git pull` directly. GraphHopper checks every profile's stored hash when
it loads a graph, and that hash covers the custom model's contents, so a config
that has moved on from the graph beside it will not start. Since the unit is
`Restart=on-failure`, a pull under a live instance means it never comes back
from its next crash. And bash reads a script as it runs it, so a pull that lands
mid-import can leave `gh-update.sh` executing the tail of a different file.

`deploy.sh` avoids both by taking the lock `gh-update.sh` holds for the whole of
a run, and by freezing what is running now before the templates move. Nothing
reads the templates directly — an instance reads `run/instance.<i>/`, written
when its graph was built, which is why the two can never disagree.

### Migrating an install that predates the freeze

Once, on a checkout whose `gh-update.sh` does not take the lock yet, so this is
the one deployment that has to wait the hard way.

Run the whole block **as root**, in `tmux`, and leave it — the loop does the
waiting. Root because none of the timer and unit commands here are in the
passwordless sudoers set, and a `sudo` partway down would sit at a password
prompt hours later with nobody there to answer it. The file operations drop
back to the service user with `runuser`, so nothing in the checkout ends up
owned by root.

```bash
systemctl stop gh-update.timer

# Not `systemctl is-active`: gh-update.service is Type=oneshot with no
# RemainAfterExit, so while its ExecStart is running the unit sits in
# `activating`, which is-active reports as false. The loop would fall straight
# through into a live import — the one thing this block exists to avoid.
while :; do
  state="$(systemctl show -p ActiveState --value gh-update.service)"
  case "$state" in inactive | failed) break ;; esac
  sleep 60
done

cd /opt/graphhopper

# What the live instance is running on, captured before the pull moves it.
# freeze-config.sh is not here yet, hence by hand. The live side only: the idle
# one's graph came from an older generation of these templates, so freezing
# today's for it would assert a match nobody established, and the next import
# rebuilds that side from scratch regardless.
#
# Which side is live comes from the nginx symlink, as it does in both updaters —
# where traffic actually goes, not which units are enabled. Unit state would be
# wrong here: an instance reads as inactive through every RestartSec hold.
#
# ONCE, and only before the pull. Run after it and these two lines would copy
# the new templates over a live instance's freeze — the very thing the freeze
# exists to prevent.
live="$(readlink graphhopper.freemap.sk)"; live="${live##*.}"
case "$live" in a | b) ;; *) echo "no live instance found: $live" >&2; exit 1 ;; esac
runuser -u freemap -- mkdir -p "run/instance.$live/custom_models"
runuser -u freemap -- cp "config-freemap.$live.yml" "run/instance.$live/config.yml"

runuser -u freemap -- git pull --ff-only

# daemon-reload restarts nothing, so the live instance keeps its old command
# line until it next stops — and when it does come back it reads the freeze
# above, which still matches the graph it has.
install -m644 graphhopper@.service /etc/systemd/system/
systemctl daemon-reload

systemctl start gh-update.timer
```

Check first that the pull will not want anything typed at it:

```bash
runuser -u freemap -- git -C /opt/graphhopper fetch --dry-run
```

From here on it is `deploy.sh`, whenever, unattended.

## Elevation

Elevation comes from Sonny's LiDAR DTM (1", Europe), not SRTM. The tiles are
downloaded by hand into `sonny-dem/` — GraphHopper cannot fetch them — and the
data is CC BY 4.0, so **freemap.sk has to credit Sonny with a link to
sonny.4lima.de** in its map/routing attribution (that credit lives in
`freemap-v3-react`).

Sonny only covers Europe, and a cell with no tile does **not** degrade to flat
terrain — it fails the import outright. The gaps our extract reaches (eastern
Turkey, the Caucasus, North Africa) are filled with 3" tiles from the old
`srtmprovider/` cache, so **that directory must be kept**.

See [sonny-tiles.md](sonny-tiles.md) for where the tiles come from, how the
cache directory has to look, why an uncovered cell is fatal, and how to fill new
gaps.

`sonny` is in no GraphHopper release, so the deployed jar is a local build —
see [Building the jar](#building-the-jar).

## Building the jar

`graphhopper-web-11.0.jar` is **not** the official release jar. Two commits are
cherry-picked onto the 11.0 tag, and two more are applied from `patches/`.

The `sonny` elevation provider was added in
[#3183](https://github.com/graphhopper/graphhopper/pull/3183) on 2025-11-12,
four weeks after 11.0 was tagged, and is still unreleased — as of 2026-09, 11.0
remains the newest release and the commit exists only on `master`
(`12.0-SNAPSHOT`). The stock jar aborts the import with
`IllegalArgumentException: Did not find elevation provider: sonny`.

The second, [#3235](https://github.com/graphhopper/graphhopper/pull/3235) of
2025-12-02, is one line: elevation sampling skips ferries. It matters because
`graph.elevation.long_edge_sampling_distance` is set, and `limit.geojson`
reaches every sea Europe has — Adriatic, Baltic, North Sea, Aegean, the Channel
— so without it every ferry way in the graph collects a point per 60 m.

The third is ours to carry: `patches/0003-max-slope-short-segments.patch`, a
backport of upstream `5697f586b40a`.

`SlopeCalculator` returns early for edges below `MIN_LENGTH` (8 m) and, in 11.0,
sets only `average_slope` to 0 on that path. `MaxSlope` is created with
`negateReverseDirection`, which gives it a `minStorableValue` of -31, so an
untouched `max_slope` decodes to **-31 % forward and +31 % reverse**. Every
sub-8 m edge in the graph — kerb crossings, sidewalk links, junction stubs —
therefore reports a sentinel indistinguishable from a real 31 % ramp. It went
unnoticed upstream because no built-in custom model reads `max_slope`; ours do,
and `stroller.json` blocking on `|max_slope| > 12` severed the pedestrian graph
into unreachable fragments. Upstream's own fix does not cherry-pick, because
#3293 had already moved the calculation to a post-import `execute(Graph)` pass,
so the two lines are reapplied to 11.0's `TagParser` form by hand.

The fourth is ours outright, with no upstream counterpart:
`patches/0004-trail-colours.patch` adds the encoded values `hiking_colours` and
`bike_colours`, so a route can be drawn in the colours of the waymarked trails
it follows. Each is a 9-bit mask — red, blue, green, yellow, black, orange,
gray, white, and `other` for the recognisable rest (brown, purple, teal, hex
values) — filled from the route relations an edge belongs to: `route=hiking`
and `route=foot` for the first, `route=bicycle` and `route=mtb` for the second.
The client asks for `details=hiking_colours` or `details=bike_colours`
depending on the profile, and decodes the bits; a segment shared by a red and a
green trail returns both, because relations OR into the mask rather than
competing for it.

The web app has to wait for the switchover before it starts asking. An unknown
path detail is not ignored — `PathDetailsBuilderFactory` throws, failing the
whole route request — so a frontend deployed ahead of the first coloured graph
breaks routing rather than losing a colour.

Colour is read from the first field of `osmc:symbol` and falls back to `colour`,
then to the rarer `color` spelling. Both tags are needed: across Europe 69 % of `route=hiking` relations carry
`osmc:symbol` against 18 % with `colour`, while for `route=bicycle` it is 2 %
against 16 %.

The nine bits are not arbitrary, but they are measured rather than derived. Edge
flags are allocated in whole 4-byte ints; this exact `graph.encoded_values` list
sits at `bytesForFlags` 22, i.e. 6 ints, and adding two 9-bit masks leaves it at
24 bytes — still 6 ints, so they cost **nothing**. A tenth bit on both takes the
graph to 7 ints, four more bytes on every edge.

That does not follow from counting spare bits. The slack inside those six ints is
fragmented, and `IntEncodedValueImpl.init` will not let a value straddle an int
boundary, so whether a 9-bit mask fits depends on the whole list and on where the
key sorts into it. Re-measure after any change to that line before widening
either mask.

Rather than run `12.0-SNAPSHOT` — ten months of unreleased changes, including
`CustomWeighting` returning 10× its previous values, `max_speed` becoming a
required encoded value, and country rules moving into parsers — the release is
used with those commits applied. The two cherry-picks go cleanly: 11.0 already
has the `AbstractSRTMElevationProvider` constructor #3183 builds on, and the PR
only adds two self-contained classes plus four lines of dispatch in
`GraphHopper.java`, while #3235 is a single condition in `OSMReader`.

```bash
git clone https://github.com/graphhopper/graphhopper.git
cd graphhopper
git checkout -b 11.0-sonny-ferry-slope 11.0
git cherry-pick 25903cd0c6cfd23e1e72da71900b26dc2cfc362f    # #3183 sonny provider
git cherry-pick 75fb59df438bf6e536da51f4e453ad978149f355    # #3235 skip ferries
git am < /opt/graphhopper/patches/0003-max-slope-short-segments.patch
git am < /opt/graphhopper/patches/0004-trail-colours.patch
mvn -DskipTests -pl web -am package
```

Both patches carry tests, so it is worth running those classes rather than
trusting the build. `-DfailIfNoTests=false` is required, not optional: `-am`
also runs the `test` phase in `web-api`, where the filter matches nothing and
Surefire would otherwise abort the reactor.

```bash
mvn -pl core -am test -Dtest=SlopeCalculatorTest,OSMTrailColourParserTest -DfailIfNoTests=false
```

Check all four landed. A jar silently missing one is the expensive failure: the
import does not complain, it just aborts on `sonny`, quietly fattens every ferry
line, writes the `max_slope` sentinel that took a working stroller profile down
to "Connection between locations not found", or — for the colours — refuses to
start at all, since `graph.encoded_values` names two encoded values a stock jar
has never heard of.

```bash
J=web/target/graphhopper-web-11.0-SNAPSHOT.jar
unzip -l "$J" | grep SonnyProvider
unzip -p "$J" com/graphhopper/reader/osm/OSMReader.class > /tmp/OSMReader.class
javap -p -c /tmp/OSMReader.class \
  | awk '/getLongEdgeSamplingDistance/{f=1} f{print} /EdgeSampling.sample/{if(f)exit}' \
  | grep isFerry     # must print a line; empty means #3235 is missing

unzip -p "$J" com/graphhopper/routing/util/SlopeCalculator.class > /tmp/SC.class
javap -p -c /tmp/SC.class \
  | awk '/double 8.0d/{f=1} f&&/return/{exit} f' \
  | grep -c maxSlopeEnc   # must print 2; 0 means the max_slope patch is missing

unzip -l "$J" | grep -c TrailColour   # must print 2; 0 means the colours patch is missing
```

The tag's pom says `11.0-SNAPSHOT`, so the artifact has to be renamed to
`graphhopper-web-11.0.jar` — both `graphhopper@.service` and `gh-update.sh`
hardcode that name.

Install it by **rename, not in place**: a running instance holds the jar open,
and truncating it under the JVM breaks lazy class loading.

```bash
sudo install -o freemap -g freemap -m 644 new.jar /opt/graphhopper/.gh-new.jar
sudo mv -f /opt/graphhopper/.gh-new.jar /opt/graphhopper/graphhopper-web-11.0.jar
```

The new jar takes effect for *serving* at the next instance start, which the
update script does as part of its normal switchover. It takes effect for the
data at the next **import**, which is a separate JVM invocation — so anything
the patches change about what gets written to the graph, `max_slope` included,
only appears once that instance has been rebuilt.

Once a release contains the first three — #3183, #3235 and `5697f586b40a` —
most of this section goes away, but not all of it. `0004-trail-colours.patch`
has no upstream counterpart and never will be released; it has to be reapplied
to whatever release replaces this one, or the jar refuses to start against a
`graph.encoded_values` that names `hiking_colours`. Until then a release
carrying only some of the three still needs whichever checks above it does not
cover. Read the 12.0 migration notes before
jumping, and re-verify `max_slope` on a flat urban route afterwards, since #3293
rewrote how it is derived.

## Failure Handling

Failures are split into two kinds, because the mirror being briefly unreachable
is not the same as a broken import.

**Recoverable** — anything network-shaped: the checksum probe or the download
failing, the mirror serving an error page instead of a checksum, a corrupt
download. `wget` already retries these a few times within the run; if they still
fail the run ends quietly, leaving the schedule alone so the next hourly run
tries again. A partially downloaded `.pbf` is kept and resumed. Only every
`NOTIFY_AFTER_FAILURES` (6) consecutive such runs sends an email.

**Hard** — `osmium extract` failing, the GraphHopper import failing, the new
instance never becoming healthy, any of the systemd/nginx switchover steps
failing, or any unanticipated error. These need a human, so the script writes
`run/halted` and emails. Every later run reads that file, prints why, and exits
without doing anything. A downloaded and verified `.pbf` is left in place, so
the retry after a fix does not re-download it.

Two cases deliberately cross over from recoverable to hard, because retrying
them hourly costs more than it can ever gain:

- `wget` exiting 3 (local file I/O error — typically a full disk).
- The same remote checksum failing to verify twice in a row. The first mismatch
  is retried once; a second one means the mirror or the disk is broken, not
  unlucky, and a ~35 GB re-download per hour is not a reasonable way to find out.

Halting with a file rather than by stopping `gh-update.timer` needs no
privileges, and unlike a stopped timer unit it survives a reboot — a stopped
timer is re-armed at boot and, with `Persistent=true`, fires straight away.

## Setup

### 1. Config file

```bash
cp gh-update.conf.example gh-update.conf
chmod 600 gh-update.conf
# fill in MAILGUN_API_KEY, MAILGUN_DOMAIN, NOTIFY_EMAIL
```

### 2. GraphHopper jar

Build it — the official release has no `sonny` provider. See
[Building the jar](#building-the-jar). The result belongs in this directory as
`graphhopper-web-11.0.jar` (gitignored).

### 3. Elevation tiles

Install Sonny's DTM tiles into `sonny-dem/` before the first import — see
[sonny-tiles.md](sonny-tiles.md). Without them the import fails on the first
node it cannot find a tile for.

### 4. Graph directories

`graph-cache.{a,b}` must exist before the first run — as symlinks to wherever
the graphs really live, or as plain directories to keep them here. The update
script refuses to import into a path that is neither, because `readlink -f`
happily resolves a name that is not there and the import would then land on the
checkout's own filesystem with nothing to show that it had.

```bash
ln -s /fm/data4/graphhopper-data/graph-cache.a graph-cache.a
ln -s /fm/data4/graphhopper-data/graph-cache.b graph-cache.b
```

The targets themselves are created on first import.

### 5. Sudoers

```
freemap ALL=(root) NOPASSWD: /bin/systemctl reload nginx, \
  /bin/systemctl enable --now graphhopper@a, /bin/systemctl enable --now graphhopper@b, \
  /bin/systemctl disable --now graphhopper@a, /bin/systemctl disable --now graphhopper@b, \
  /bin/systemctl enable --now photon@a, /bin/systemctl enable --now photon@b, \
  /bin/systemctl disable --now photon@a, /bin/systemctl disable --now photon@b
```

### 6. Install and enable units

```bash
cp graphhopper@.service gh-update.service gh-update.timer gh-update-abort.service \
  /etc/systemd/system/
chmod +x gh-update.sh notify.sh freeze-config.sh deploy.sh
systemctl daemon-reload

# Start whichever graphhopper instance is currently active (e.g. a).
# The update script will enable/disable instances automatically on each update.
#
# It needs a freeze first — ExecStartPre asserts one rather than inventing it,
# so an instance with no run/instance.<i>/ will not start. Creating it from
# today's templates is only honest if this graph was built from this checkout;
# if the graph came from a backup, restore its freeze alongside it instead.
sudo -u freemap ./freeze-config.sh a
systemctl enable --now graphhopper@a.service

# Enable the timer (replaces cron)
systemctl enable --now gh-update.timer
```

For Photon, the equivalent units are `photon@.service`, `photon-update.service`,
`photon-update.timer` and `photon-update-abort.service`, installed from the
`/opt/photon` checkout.

`photon-update.timer` is `Persistent=true`. Enabling it with no
`/var/lib/systemd/timers/stamp-photon-update.timer` present can trigger a run
on the spot — a 13 GB download and a ~7h import. `touch` that stamp as root
first if you want `enable --now` to be a no-op until the next scheduled hour.

## Logs

```bash
journalctl -u gh-update.service       # update job
journalctl -u graphhopper@a.service   # instance a
journalctl -u graphhopper@b.service   # instance b
```

## After a Hard Failure

`run/halted` says when it happened and why. Read it, fix the cause, then:

```bash
rm /opt/graphhopper/run/halted                # resume hourly runs
systemctl reset-failed gh-update.service      # clear the failed unit state
systemctl start --no-block gh-update.service  # optional: trigger immediately
```

`gh-update.service` is `Type=oneshot`, so `systemctl start` blocks until the
whole update finishes (downloading the OSM extract + importing can take a long
time). Use `--no-block` to return immediately and let it run in the background;
follow progress with `journalctl -fu gh-update.service`.
