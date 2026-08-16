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
  and caching config cannot drift between the two sides.
- The health check requires an actual geocoding result: an index that is open
  but empty answers 200 with no features, and a status-only check would switch
  traffic to a geocoder that finds nothing.
- After every switchover the nginx proxy cache is purged — the vhost caches
  responses for 24h and would otherwise keep serving the retired index.

Moving the existing hand-built instance onto this setup is a one-time sequence
with a couple of order-dependent steps — see
[photon-migration.md](photon-migration.md).

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
5. Imports the data into the inactive instance (`a` or `b`).
6. Starts the new instance via systemd and polls until it is healthy.
7. Switches nginx to the new instance and stops the old one.
8. Emails the result.

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

`graphhopper-web-11.0.jar` is **not** the official release jar. The `sonny`
elevation provider was added in
[#3183](https://github.com/graphhopper/graphhopper/pull/3183) on 2025-11-12,
four weeks after 11.0 was tagged, and is still unreleased — as of 2026-08, 11.0
remains the newest release and the commit exists only on `master`
(`12.0-SNAPSHOT`). The stock jar aborts the import with
`IllegalArgumentException: Did not find elevation provider: sonny`.

Rather than run `12.0-SNAPSHOT` — ten months of unreleased changes, including
`CustomWeighting` returning 10× its previous values and country rules moving
into parsers — the release is used with that one commit cherry-picked. It
applies cleanly: 11.0 already has the `AbstractSRTMElevationProvider`
constructor it builds on, and the PR only adds two self-contained classes plus
four lines of dispatch in `GraphHopper.java`.

```bash
git clone https://github.com/graphhopper/graphhopper.git
cd graphhopper
git checkout -b 11.0-sonny 11.0
git cherry-pick 25903cd0c6cfd23e1e72da71900b26dc2cfc362f    # #3183
mvn -DskipTests -pl web -am package
unzip -l web/target/graphhopper-web-11.0-SNAPSHOT.jar | grep SonnyProvider   # sanity check
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

The new jar takes effect at the next instance start, which the update script
does as part of its normal switchover. Once a release finally contains #3183
this section goes away — but read the 12.0 migration notes before jumping.

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

### 4. Sudoers

```
freemap ALL=(root) NOPASSWD: /bin/systemctl reload nginx, \
  /bin/systemctl enable --now graphhopper@a, /bin/systemctl enable --now graphhopper@b, \
  /bin/systemctl disable --now graphhopper@a, /bin/systemctl disable --now graphhopper@b, \
  /bin/systemctl enable --now photon@a, /bin/systemctl enable --now photon@b, \
  /bin/systemctl disable --now photon@a, /bin/systemctl disable --now photon@b, \
  /usr/bin/find /fm/data4/nginx-proxy-cache/photon -mindepth 1 -delete
```

### 5. Install and enable units

```bash
cp graphhopper@.service gh-update.service gh-update.timer gh-update-abort.service \
  /etc/systemd/system/
chmod +x gh-update.sh notify.sh
systemctl daemon-reload

# Start whichever graphhopper instance is currently active (e.g. a).
# The update script will enable/disable instances automatically on each update.
systemctl enable --now graphhopper@a.service

# Enable the timer (replaces cron)
systemctl enable --now gh-update.timer
```

For Photon, the equivalent units are `photon@.service`, `photon-update.service`,
`photon-update.timer` and `photon-update-abort.service`, installed from the
`/opt/photon` checkout — see [photon-migration.md](photon-migration.md).

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
