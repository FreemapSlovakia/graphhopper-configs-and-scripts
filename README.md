# GraphHopper Update Scripts

These scripts keep GraphHopper routing data up to date using systemd timers and services.

## Scripts

- `gh-update.sh` — downloads OSM data, imports it into the inactive instance, switches nginx to it, stops the old instance, and emails the result.
- `gh-notify.sh` — sends one Mailgun email. Called by `gh-update.sh` with a subject and a body on stdin, or by systemd with `--abrupt` when the update died before it could report.

State kept between runs in `run/`:

| File              | Meaning                                                      |
| ----------------- | ------------------------------------------------------------ |
| `osm.md5`         | Checksum line of the currently imported extract               |
| `downloading.md5` | Checksum the partially downloaded `.pbf` is expected to have  |
| `downloaded.md5`  | Checksum of a fully downloaded and verified `.pbf`            |
| `mismatch.md5`    | Checksum that already failed verification once                |
| `fail-streak`     | Consecutive recoverable failures                              |
| `halted`          | Present = every run exits immediately until it is removed     |

## Systemd Units

| Unit                       | Purpose                                              |
| -------------------------- | ---------------------------------------------------- |
| `graphhopper@.service`     | GraphHopper routing server (instances `a` and `b`)   |
| `gh-update.service`        | Oneshot update job                                   |
| `gh-update.timer`          | Triggers `gh-update.service` hourly                  |
| `gh-update-abort.service`  | `OnFailure=` backstop for an update that was killed  |

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

See [sonny-tiles.md](sonny-tiles.md) for where the tiles come from, how the
cache directory has to look, how missing tiles fail silently, and the
GraphHopper version this provider needs.

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

### 2. Elevation tiles

Install Sonny's DTM tiles into `sonny-dem/` before the first import — see
[sonny-tiles.md](sonny-tiles.md). Without them every route comes out flat.

### 3. Sudoers

```
freemap ALL=(root) NOPASSWD: /bin/systemctl reload nginx, \
  /bin/systemctl enable --now graphhopper@a, /bin/systemctl enable --now graphhopper@b, \
  /bin/systemctl disable --now graphhopper@a, /bin/systemctl disable --now graphhopper@b
```

### 4. Install and enable units

```bash
cp graphhopper@.service gh-update.service gh-update.timer gh-update-abort.service \
  /etc/systemd/system/
chmod +x gh-update.sh gh-notify.sh
systemctl daemon-reload

# Start whichever graphhopper instance is currently active (e.g. a).
# The update script will enable/disable instances automatically on each update.
systemctl enable --now graphhopper@a.service

# Enable the timer (replaces cron)
systemctl enable --now gh-update.timer
```

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
