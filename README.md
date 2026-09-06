# Freemap Routing & Geocoding Ops

Scripts that keep the **GraphHopper** routing data and the **Photon** geocoding
index up to date, using systemd timers and services.

Both follow the same shape — check a remote checksum, download and verify,
import into the idle instance, health-check it, flip nginx, check that nginx
really flipped, retire the old one — so the machinery is shared and only the
service-specific steps differ.

## Everyday operations

| Task | Command |
| ---- | ------- |
| Deploy a change to any script, config, model or unit | `sudo -u freemap /opt/graphhopper/deploy.sh` |
| …one that also touches `patches/` | `sudo -u freemap /opt/graphhopper/deploy.sh --jar` |
| Make a deployed change reach a graph | `sudo -u freemap /opt/graphhopper/reimport.sh` |
| …replacing an import already in flight | `sudo -u freemap /opt/graphhopper/reimport.sh --restart` |
| Check a patch still builds, installing nothing | `sudo -u freemap /opt/graphhopper/build-jar.sh` |
| Resume after a hard failure | `sudo -u freemap rm /opt/graphhopper/run/halted` |
| Watch a run | `journalctl -fu gh-update.service` |
| See which instance is live | `curl -sI https://graphhopper.freemap.sk/ \| grep -i x-gh-instance` |

None of these touches what is currently serving. A **recoverable** failure needs
nothing at all — the next hourly run retries by itself; only a **hard** one
leaves `run/halted` for a human. Details in [Deploying a change](#deploying-a-change),
[Forcing an import](#forcing-an-import) and [After a failure](#after-a-failure).

## Scripts

| Script             | Role                                                                   |
| ------------------ | ---------------------------------------------------------------------- |
| `common.sh`        | Shared scaffolding: failure classification, halting, retries, downloads |
| `gh-update.sh`     | GraphHopper: OSM extract → import → switchover                          |
| `photon-update.sh` | Photon: JSONL dump → import → switchover                                |
| `freeze-config.sh` | Pins the config, models, jar and feeds to the graph being built         |
| `deploy.sh`        | `git pull` that waits for the gap between imports; `--jar` rebuilds too |
| `build-jar.sh`     | Builds the patched GraphHopper jar and proves every patch landed        |
| `reimport.sh`      | Spends an import on a config or jar change the mirror did not trigger   |
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
| `force`               | A re-import has been asked for; taken by the next run to start |
| `forcing`             | That request, in progress; cleared only by an import that finished |
| `aborting`            | Invocation ID of a run being killed on purpose — `reimport.sh` |
| `gtfs/`               | Latest good copy of each GTFS feed, refreshed per import     |
| `instance.{a,b}/`     | The config, custom models, jar and GTFS feeds that instance's graph was built from |
| `update.lock`         | Held by a run, and by `deploy.sh` while it pulls and builds   |

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
3. Script checks if new OSM data is available; exits silently if not — unless
   `run/force` says to import anyway (see [Forcing an import](#forcing-an-import)).
4. If yes, downloads the extract (resuming a partial one) and verifies its checksum.
5. Freezes `config-freemap.<i>.yml` and `custom_models/` into `run/instance.<i>/`.
6. Imports the data into the inactive instance (`a` or `b`), from that freeze.
7. Starts the new instance via systemd and polls until it is healthy.
8. Switches nginx to the new instance, then confirms through nginx that the new
   instance is the one answering.
9. Stops the old one.
10. Emails the result.

## Switchover

One vhost, `graphhopper.freemap.sk`, which `include`s `graphhopper-upstream.conf`
inside its `location /`. That is a symlink, flipped between
`graphhopper-upstream.{a,b}.conf` — two files of two lines each, a `proxy_pass`
and an `add_header`. The same shape as Photon, and for the same reason: the TLS
config, the body limit and the log paths live in one place, so they cannot drift
between the two sides, and there is exactly one line per side left to get wrong.

It used to be two complete vhosts differing only in the port. On 2026-09-06 the
`b` copy was overwritten by a copy of the `a` one, and the next switchover
pointed every request at the instance it was about to stop: routing was down for
an hour and three quarters, and nothing in the run noticed, because the readiness
poll asks `127.0.0.1:9989` directly and that instance was perfectly healthy.

So two things guard the flip now, from opposite ends:

- **Before it**, `gh-update.sh` asserts that the fragment it is about to switch
  to names the port the new instance just answered on. A mismatch here costs
  only the run — nothing has moved yet.
- **After it**, `verify_through_nginx` sends the same `/route` probe to
  `https://graphhopper.freemap.sk/` (with `--resolve`, so it can only be this
  box's nginx answering) and requires the `X-GH-Instance` header to name the new
  side. A status-only check would not do: the failure being caught answers 200
  until the old instance is stopped. On failure the symlink goes back, nginx is
  reloaded again, the new side is retired — left enabled it would be the one the
  next run tried to import into, and that run would refuse, hourly, to clear a
  graph something is running on — and the run halts with the old side serving.

Neither subsumes the other. A fragment overwritten wholesale fails the first
check; one whose port was corrected but whose header was not fails the second.
`X-GH-Instance` is also on every public response, so which side is live can be
read with `curl -I` from anywhere.

## Deploying a change

Everything in this repository deploys the same way — a script, a systemd unit,
`config-freemap.{a,b}.yml`, `custom_models/`, `limit.geojson`. Push, then on the
server:

```bash
sudo -u freemap /opt/graphhopper/deploy.sh
```

Any time — it waits for the gap between imports by itself and needs no
watching.

When it takes effect depends on what moved. A script is in force the moment it
lands. A systemd unit is not: `deploy.sh` refuses to finish quietly and prints
the `install` line to run as root, because an instance left on the old
`ExecStart` is the failure all of this exists to prevent. The config, the models
and the jar are *templates* — an instance runs the copy frozen into
`run/instance.<i>/` when its graph was built — so those reach users only at the
next import, one instance at a time, and the live instance is not touched.
[Forcing an import](#forcing-an-import) is how to stop that waiting for
Geofabrik.

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

### Deploying a jar change

Push a change under `patches/`, then:

```bash
sudo -u freemap /opt/graphhopper/deploy.sh --jar
```

Same command, same lock, one extra step: after the pull it runs `build-jar.sh`
and installs what that produced, still holding the lock. The build reads
`patches/` out of the checkout, so pulling and building cannot be two commands —
an import starting between them would freeze new custom models against a jar
that has never heard of the encoded values they name.

**Nothing in service moves.** A serving instance and a running import both read
`run/instance.<i>/graphhopper.jar`, frozen when that graph was built; installing
a template replaces only what the *next* import will freeze. The lock is not
there to protect them, it is there to protect the freeze itself, which copies
config, models and jar as one set — a template swap landing in the middle of
that would pair half of one generation with half of another.

The build takes minutes and the lock is held throughout. An hourly run arriving
meanwhile waits for it; if it waits past its patience it retires as a
recoverable failure and tries again next hour, which costs an hour of staleness
and nothing else.

`build-jar.sh` can also be run on its own, any time, including while an import
is running. It writes only under `build/`, installs nothing, and nothing reads a
jar from there — so it is the way to find out whether a patch still applies and
still passes its tests before committing to a deploy.

### Forcing an import

Neither a config change nor a jar change reaches a graph without an import, and
the hourly run imports only when Geofabrik's checksum has moved. To spend one
deliberately:

```bash
sudo -u freemap /opt/graphhopper/reimport.sh              # after the current run
sudo -u freemap /opt/graphhopper/reimport.sh --restart    # kill the current one first
```

`reimport.sh` writes `run/force` and starts `gh-update.service`, so the forced
run happens inside the unit — same journal, same `Nice=`, same `OnFailure=` — as
any other.

A run takes the request by renaming `run/force` to `run/forcing`, and only
`run/forcing` is cleared, only by an import that finished. Two files because
both of these have to hold: a request made *while* an import is already running
belongs to the next one, since this one is building a graph from what was there
before — so it must not be cleared by the run that did not honour it; and a
request must outlive a run that failed, so a mirror hiccup means the next hourly
run still does the import that was asked for.

`--restart` is for the case where the deploy landed while an import was already
running, and that import is therefore building a graph from what was there
before. It stops the service, which kills the import with it, and retires any
instance the killed run had already started — an import cut short after its
instance came up but before nginx moved leaves that instance serving a half-built
graph, and the next run rightly refuses to clear a graph something is serving
from. The live side, the one the nginx symlink names, is never touched.

Killing a run has to be told apart from a run that died, or the kill halts the
schedule it was meant to restart. Measured, not assumed: a `systemctl stop`
mid-import leaves the unit `Failed with result 'signal'`, fires `OnFailure=`, and
`gh-update-abort.service` writes `run/halted` — so the run started a second later
reads that file and does nothing, and the import silently never happens.

`reimport.sh` therefore writes the systemd **invocation ID** of the run it is
killing into `run/aborting`, and `common.sh` and `notify.sh` compare it against
their own before halting or mailing. By invocation rather than by age, so it
cannot also excuse the fresh run started seconds later. The full account is in
the comments on those three files.

Either form re-downloads the extract: the last successful run deleted it and the
import has to read something. Budget for the whole run, some fifteen hours, not
for the minutes the change took to write.

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

## Pedestrian Routing

The four pedestrian profiles read our own copies of GraphHopper's models rather
than the jar's:

| file | what it is |
| ---- | ---------- |
| `fm_foot.json` | the jar's `foot.json`, rule bodies byte-identical |
| `fm_hike.json` | the jar's `hike.json`, likewise |
| `foot_carriageway.json` | ours — how much worse a carriageway is than a footway |
| `foot_temporal.json` | ours — conditional closures, an access rule |

```
foot      → fm_foot.json, foot_elevation.json, foot_carriageway.json, foot_temporal.json
hike      → fm_hike.json, foot_elevation.json, foot_carriageway.json, foot_temporal.json
stroller  → fm_foot.json, foot_elevation.json, stroller.json, foot_carriageway.json, foot_temporal.json
easyhike  → fm_hike.json, foot_elevation.json, easyhike.json, foot_carriageway.json, foot_temporal.json
```

Copied rather than referenced because the built-ins are not stable — #3226 already
moved route handling out of `bike.json` into custom models upstream — and walking
routes changing because the jar was rebuilt for an elevation provider is not
something we would notice for weeks. The cost is a diff to read at each jar
rebuild; it belongs in the build checklist below, and the bodies are kept
byte-identical so that diff stays silent until upstream actually changes
something.

`multiply_by: foot_priority` is the one rule that cannot be rewritten out.
`FootPriorityParser` is Java, and its output is the only representation we have of
`foot=designated`, `foot=use_sidepath`, `sidewalk=no|none|separate`,
`bicycle=designated` and "maxspeed ≤ 20 counts as safe". None of those is an
encoded value in 11.0.

### The road ladder

Where sidewalks are mapped as separate footways rather than as `sidewalk=*` on the
road, the road centreline is shorter and straighter than the sidewalk with its
detours via crossings, so the router walks pedestrians down the road. Reproduced
at Repašského, Bratislava (`48.189755/17.032993 → 48.190370/17.036051`): the route
ran `footway ×12 → tertiary → residential → footway`. The ladder makes it 267 m of
footway throughout, 9 m longer.

Effective values, `foot_priority` × the ladder:

| | |
| --- | --- |
| footway, pedestrian, path, track, steps, living_street | 1.20 |
| residential | 1.14 |
| service | 1.08 |
| unclassified | 1.00 |
| tertiary | 0.95 *(0.76 if `sidewalk=no\|none\|separate`)* |
| secondary | 0.56 *(0.35)* |
| primary | 0.40 *(0.25)* |

Every value is measured rather than chosen — the sweep, and why `tertiary` is 0.95
and not 0.9, is in `foot_carriageway.json`. Two properties worth keeping if anyone
retunes it: it only ever multiplies by ≤ 1, which is the shape a *query* custom
model is allowed to have, and it leaves `path` and `track` at what
`foot_priority` gives them, so a hiker still prefers a path (1.20) to a tertiary
road (0.95).

The bracketed values are the ones GraphHopper ought to use far more often than it
does. `FootPriorityParser` reads only the legacy `sidewalk` key, so
`sidewalk:both=separate` — now the commoner spelling in Europe, 272k ways against
242k — is invisible, and the road is promoted two rungs instead of demoted. That
is the actual cause of the Repašského case; the ladder compensates for it. See
[graphhopper/graphhopper#3042](https://github.com/graphhopper/graphhopper/pull/3042).

## Public Transport

`gtfs.file` in the config is what makes the instance PT-capable: `GraphHopperManaged`
builds a `GraphHopperGtfs` when it is present, which adds `/route-pt` and
`/isochrone-pt`. `PtRedirectFilter` forwards `/route?profile=pt` to the former, so
the web app can treat it as one more entry in the profile list and nginx needs no
new location — the vhost already proxies everything.

It is not a profile, though. There is no entry under `profiles:`, no custom model,
no CH or LM, and `pt.earliest_departure_time` is mandatory: a PT request needs a
departure time, which no other mode does. `pt.access_profile` and
`pt.egress_profile` pick which of our profiles walks the first and last legs, so
passing `bike` gives bike-and-ride for free. Speed mode is untouched —
`postProcessing` imports the timetable and then prepares CH and LM as before.

`patches/0005` adds `pt.blocked_route_types`, a bitmask of GTFS `route_type`s to
leave out: `4` drops rail, `8` drops buses. Our feeds map onto modes cleanly enough
for that to be useful — ZSSK is entirely `route_type=2`, DPB is tram, bus and
trolleybus — but it cannot separate Bratislava's buses from Prešov's, since both
are `route_type=3`. They do not overlap geographically, so in practice that costs
nothing.

### Feeds

| Feed | Source | Licence |
| ---- | ------ | ------- |
| `zssk` | Every Slovak train, via the national open data catalogue | — |
| `dpb`  | Dopravný podnik Bratislava, ArcGIS item behind data.bratislava.sk | **CC BY 4.0** |
| `presov` | Dopravný podnik mesta Prešov, ArcGIS item, published by R&G PLUS | **CC BY 4.0** |

Both URLs are in `GTFS_FEEDS` in `gh-update.sh`, with the reasoning beside them.
Neither is the address a feed directory will give you: the `gtfs.zip` on `zsr.sk`
that Transitland and the Mobility Database still list redirects to a landing page
and carries nothing, and the `opendata.bratislava.sk` URLs they list for DPB are
dead — the city moved to an ArcGIS Hub site. The train feed is only discoverable
through the catalogue's SPARQL endpoint at `data.slovensko.sk/api/sparql`, since
the catalogue front end is a single-page app.

DPB and Prešov are both **CC BY 4.0**, so freemap.sk has to credit them wherever PT
results are shown, the same obligation the Sonny tiles carry.

Feeds carry their own validity and do not clamp each other: `GtfsReader` builds each
trip's validity from its own feed's calendar. The "Calendar range covered by all
feeds" line at import is the intersection of them all and is **logged only** — a
short or lapsed feed does not shorten the others. What a lapsed feed does do is
contribute stops with no departures, since GTFS has no way to say "runs
indefinitely": an operator has to republish with extended dates, and until they do,
those services simply do not exist as far as any router is concerned. Prešov's
calendar covers about three months at a time against DPB's four and ZSSK's twelve,
so it is the one to check first if Prešov goes quiet.

**IDS BK is not here yet.** The regional buses around Bratislava would be the
biggest coverage win left — 67 routes over 1114 stops — but the feed's official
source is a Google Drive *folder* rather than a stable file URL, and the
third-party mirrors carry a calendar that lapsed on 2026-08-31. It needs a durable
URL and a live calendar before it is worth importing.

**Košice is not here on purpose.** `opendata.kosice.sk` publishes "Cestovný poriadok
MHD", but the file is JDF — `CIS.ZIP` with `DOPRAVCI.TXT`, `LINKY.TXT`, `SPOJE.TXT`
— not GTFS, and the timetable inside is dated 2022. It needs a JDF→GTFS conversion
and a fresher source before it can be added.

### How a feed reaches a graph

`gh-update.sh` fetches each feed into `run/gtfs/` right after the OSM extract, and
before the graph cache is cleared, so a feed that cannot be fetched stops the run
while the idle instance still has the graph it would otherwise fall back on. Each
download is validated as an intact zip carrying the files GraphHopper's GTFS reader
needs; anything else is discarded.

**A failed refresh keeps the last good copy.** A transit operator's web server
having a bad morning is not a reason to skip a day of European routing, and a
timetable a week stale still routes. Only the absence of any copy is fatal, because
then the import has nothing to read.

`freeze-config.sh` then pins the feeds into `run/instance.<i>/gtfs/` alongside the
config and models, and the config points there rather than at `run/gtfs/`. Same
reason as the models: every later run overwrites `run/gtfs/`, so a shared path
would name files whose contents have moved on from the timetable in the graph
beside them. A freeze whose config names `gtfs.file` and has no `gtfs/` fails
`--check`; one written before public transport existed does not, which is what lets
an older graph still start.

Feeds refresh only on runs that have new OSM data, since the run exits earlier when
there is none. Geofabrik publishes daily and neither feed changes more than weekly,
so a timetable is never more than a day behind its source — which is what allows
public transport to live on this graph rather than an instance of its own.

### Expected log noise

The DPB feed tags its 15 trolleybus routes `route_type=11`, which is valid in the
extended GTFS spec but outside the 0–7 range the bundled `com.conveyal.gtfs` reader
validates against. Each one logs

```
ERROR com.conveyal.gtfs.GTFSFeed: routes line N: Number 11.0 in field null outside of acceptable range [0.0,7.0]
```

at import. They are cosmetic — the routes load. Verified by reading the built graph
back: all 92 DPB routes are present, `byRouteType={0=4, 3=73, 11=15}`, 37160 trips
across 1366 stops, alongside 2177 rail routes and 2312 trips from ZSSK.

## Building the jar

`graphhopper-web-11.0.jar` is **not** the official release jar. Two commits are
cherry-picked onto the 11.0 tag, and three more are applied from `patches/`.

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
purple, white, and `other` for the recognisable rest (grey, brown, teal, hex
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

The eight named colours are the outdoor map renderer's own set (`COLORS` in
`freemap-outdoor-map/src/render/layers/routes.rs`), and `other` is the grey it
calls `none`, so a route the web app draws over these trails is coloured from
the same names and matches the map under it. **Retuning either set means
retuning both**, and a bit whose meaning changes needs a rebuilt jar and a
reimport before the graph agrees with it — the mask in an existing graph still
means what it did when it was built.

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

The fifth is a candidate for upstream rather than something to carry:
`patches/0005-pt-blocked-route-types.patch` exposes `pt.blocked_route_types` on
`/route-pt`. `Request` has carried `blockedRouteTypes` for years, all three
`PtRouter` implementations honour it, and `PtIsochroneResource` already publishes
it under exactly that name — only `PtRouteResource` never wired it up, so a caller
can exclude a mode from an isochrone but not from a journey. Four lines and two
tests. **Send it upstream before treating it as ours**: if it is merged this
becomes a backport that disappears at the next release, like the three above it,
rather than a second patch we own forever.

Rather than run `12.0-SNAPSHOT` — ten months of unreleased changes, including
`CustomWeighting` returning 10× its previous values, `max_speed` becoming a
required encoded value, and country rules moving into parsers — the release is
used with those commits applied. The two cherry-picks go cleanly: 11.0 already
has the `AbstractSRTMElevationProvider` constructor #3183 builds on, and the PR
only adds two self-contained classes plus four lines of dispatch in
`GraphHopper.java`, while #3235 is a single condition in `OSMReader`.

`build-jar.sh` is that recipe, executable:

```bash
sudo -u freemap /opt/graphhopper/build-jar.sh
```

It clones or fetches upstream into `build/`, resets a detached tree to the 11.0
tag, applies the two cherry-picks and then every `patches/*.patch` in name
order, and builds `web` with `-am`. Rebuilt from the tag on every run rather
than updated in place: a run that died half way through a `git am` leaves a tree
that looks finished and is not, and the checks below would be the only thing
standing between that and a graph built by the wrong jar.

The patches are taken from the directory rather than listed, so adding `0006` is
a commit and nothing else. The cherry-picks *are* listed, in `CHERRY_PICKS` at
the top of the script, because each is one specific unreleased upstream commit
that leaves the list the moment a release carries it.

It then runs the tests both patched classes carry rather than trusting the
build. `-DfailIfNoTests=false` is required, not optional: `-am` also runs the
`test` phase in `web-api`, where the filter matches nothing and Surefire would
otherwise abort the reactor.

Then it proves all five landed **in the artifact** — `SonnyProvider` present,
the `isFerry` condition on `OSMReader`'s sampling path, two `maxSlopeEnc`
references on `SlopeCalculator`'s short-edge return, two `TrailColour` classes,
and `pt.blocked_route_types` in `PtRouteResource`'s constant pool. That last one
needs `javap -v`, not `-c`: 0005's only trace in the bytecode is a `@QueryParam`
annotation value, which `-c` does not print — a check written with `-c` would
report it missing from a jar that has it.
A jar silently missing one is the expensive failure: the import does not
complain, it just aborts on `sonny`, quietly fattens every ferry line, writes
the `max_slope` sentinel that took a working stroller profile down to
"Connection between locations not found", or — for the colours — refuses to
start at all, since `graph.encoded_values` names two encoded values a stock jar
has never heard of.

Last, it diffs the two pedestrian models we carry copies of against upstream's,
because nothing else will ever tell you they moved. That one only warns: output
means deciding what to take, see [Pedestrian Routing](#pedestrian-routing).

The build tree and maven's repository both live under `build/` — a symlink to a
volume with room, exactly as `graph-cache.{a,b}` are, and asserted the same way.
The disk the checkout sits on is the one that fills.

Nothing is installed. `build-jar.sh` writes only under `build/`, so it is safe
to run at any moment, including during an import, and it is the way to find out
whether a patch still applies before committing to a deploy. Installing what it
built is `deploy.sh --jar`, which does both under one lock — see
[Deploying a jar change](#deploying-a-jar-change).

The tag's pom says `11.0-SNAPSHOT`, so the artifact is staged under the name it
is installed as, `graphhopper-web-11.0.jar`. That name is written down in two
places — `JAR` in `build-jar.sh` and the `jar=` line in `freeze-config.sh` —
and the script refuses to build if they disagree, so a version bump stays a
deliberate edit in both rather than a silent mismatch in one. Neither
`graphhopper@.service` nor `gh-update.sh` names a version at all: both run the
frozen copy, which is always `run/instance.<i>/graphhopper.jar`.

It is installed by **rename, not in place**: a running instance holds its jar
open, and truncating one under a JVM breaks lazy class loading. `deploy.sh --jar`
stages inside the checkout and renames, rather than moving straight out of
`build/`, which is on another filesystem where the rename would not be atomic.

What lands is the **template**. Nothing runs it: like the config and the models,
the jar is frozen per instance at `run/instance.<i>/`, and both the import and
`graphhopper@<i>` read the freeze. So a jar installed now takes effect at the
next **import**, for the data and for the serving of that graph alike — and a
live instance goes on restarting into the jar its own graph was built by, however
many times the template is replaced meanwhile.

That is the point. The jar decides what the encoded values in a graph *mean*, so
the two can part company in both directions: patch 0004 swapping the `GRAY` bit
for `PURPLE` leaves an older graph loading fine and serving the wrong colour,
while a jar that has lost an encoded value the frozen config names refuses to
start at all. Freezing it makes "which jar built this graph" a fact on disk
rather than whatever was last installed.

To put a new jar in front of traffic sooner than the next timer run, import —
`reimport.sh`, see [Forcing an import](#forcing-an-import). There is no supported
way to swap the jar under a serving graph, because there is no way to know it
still means the same thing.

Once a release contains the first three — #3183, #3235 and `5697f586b40a` —
most of this section goes away, but not all of it. `0004-trail-colours.patch`
has no upstream counterpart and never will be released; it has to be reapplied
to whatever release replaces this one, or the jar refuses to start against a
`graph.encoded_values` that names `hiking_colours`. Until then a release
carrying only some of the three still needs whichever checks above it does not
cover. Read the 12.0 migration notes before jumping, and re-verify `max_slope`
on a flat urban route afterwards, since #3293 rewrote how it is derived.

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

Build it — the official release has no `sonny` provider. `build-jar.sh` needs
maven and a JDK, and a `build/` symlink to a volume with a few GB free for the
upstream clone and maven's repository:

```bash
apt install maven
ln -s /fm/data4/graphhopper-data/build build   # freemap owns that parent; /fm/data4 does not
sudo -u freemap ./deploy.sh --jar
```

`deploy.sh --jar` builds and installs in one step, leaving the result in this
directory as `graphhopper-web-11.0.jar` (gitignored). Expect this first one to be
the slow build: it clones upstream and fills an empty maven repository before it
compiles anything.

[Building the jar](#building-the-jar) explains what the build does and why the
release alone is not enough.

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

### 5. nginx

Install the vhost and point it at a side. The vhost is in the checkout; the
symlink it includes is not, because which side is live is state, not config.

```bash
ln -s /opt/graphhopper/graphhopper.freemap.sk /etc/nginx/sites-enabled/
ln -s ./graphhopper-upstream.a.conf /opt/graphhopper/graphhopper-upstream.conf
nginx -t && systemctl reload nginx
```

The vhost is `include`d from `sites-enabled` by its path in the checkout rather
than copied, so a pull that changes it needs only a reload. Certbot writes into
the copy here, which is why the certificate lines are in the file rather than
templated.

`gh-update.sh` reads this symlink to decide which side to import into, falling
back to unit state only if it is missing — so an install without it will import
over whichever side systemd happens to name first.

### 6. Sudoers

One file per service, since the two checkouts are deployed independently.
`/etc/sudoers.d/graphopper`:

```
freemap ALL=(root) NOPASSWD: /bin/systemctl reload nginx, \
  /bin/systemctl enable --now graphhopper@a, /bin/systemctl enable --now graphhopper@b, \
  /bin/systemctl disable --now graphhopper@a, /bin/systemctl disable --now graphhopper@b, \
  /bin/systemctl stop gh-update.timer, /bin/systemctl start gh-update.timer, \
  /bin/systemctl start --no-block gh-update.service, \
  /bin/systemctl stop gh-update.service
```

and `/etc/sudoers.d/photon`:

```
freemap ALL=(root) NOPASSWD: /bin/systemctl enable --now photon@a, \
  /bin/systemctl enable --now photon@b, /bin/systemctl disable --now photon@a, \
  /bin/systemctl disable --now photon@b
```

The last two GraphHopper rules are `reimport.sh`'s, written with the exact
arguments it uses because sudo matches the whole command line — `start
gh-update.service` without `--no-block` is a different command and would be
refused. Validate with `visudo -cf` on a copy before installing over the
original: a sudoers file that does not parse takes every rule in it with it.

### 7. Install and enable units

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
# if the graph came from a backup, restore its freeze alongside it instead — and
# if that backup predates the jar being frozen, `--if-missing` completes it in
# place rather than rewriting what the backup holds.
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

## After a failure

**Recoverable — nothing to do.** The mirror was unreachable or served rubbish,
the run ended quietly, and the next hourly one tries again by itself. There is no
`run/halted`; `run/fail-streak` counts them and only every sixth sends mail. A
`run/forcing` left from `reimport.sh` survives too, so a forced import that hit a
bad mirror is still owed and still happens.

**Hard — a human is needed.** `run/halted` says when and why, and every later run
prints it and exits. Read it, fix the cause, then:

```bash
sudo -u freemap rm /opt/graphhopper/run/halted   # resume hourly runs
sudo systemctl reset-failed gh-update.service    # clear the failed unit state
```

The next hourly run picks up from there. To retry at once instead of on the hour:

```bash
sudo -u freemap /opt/graphhopper/reimport.sh
```

`reimport.sh` rather than `systemctl start`, because the sudoers rules cover it
without root, and because it imports even if the mirror has published nothing new
in the meantime — usually the case by the time a hard failure has been fixed. It
refuses to run while `run/halted` is still there, so the order above matters.
Follow either with `journalctl -fu gh-update.service`.
