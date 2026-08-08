# GraphHopper Update Scripts

These scripts keep GraphHopper routing data up to date using systemd timers and services.

## Scripts

- `gh-update.sh` — downloads OSM data, imports it into the inactive instance, switches nginx to it, stops the old instance.
- `gh-notify.sh` — sends a Mailgun email on success (only when an update was actually performed) or failure.

State kept between runs in `run/`:

| File              | Meaning                                                        |
| ----------------- | -------------------------------------------------------------- |
| `osm.md5`         | Checksum line of the currently imported extract                 |
| `downloading.md5` | Checksum the partially downloaded `.pbf` is expected to have    |
| `downloaded.md5`  | Checksum of a fully downloaded and verified `.pbf`              |
| `mismatch.md5`    | Checksum that already failed verification once                  |
| `result.<id>`     | Outcome of one run: `updated` / `skipped` / `retry` / `failed`  |
| `error.<id>`      | Failure message of one run, quoted in the email                 |
| `result`          | Copy of the last outcome, for reading by hand                   |
| `last-error`      | Copy of the last failure message, for reading by hand           |
| `fail-streak`     | Consecutive recoverable failures                                |

`<id>` is the systemd invocation ID of the run. The mailer is handed the same
ID in `$MONITOR_INVOCATION_ID` and reads — and then deletes — that run's pair of
files. This is not incidental: when the timer fires while a run is busy, which
any import longer than an hour guarantees, systemd releases the queued next run
at the same instant it starts the mailer. A single shared `run/result` gets
overwritten by that next run before the mailer can read it, and the
notification is silently lost.

## Systemd Units

| Unit                        | Purpose                                                 |
| --------------------------- | ------------------------------------------------------- |
| `graphhopper@.service`      | GraphHopper routing server (instances `a` and `b`)      |
| `gh-update.service`         | Oneshot update job                                      |
| `gh-update.timer`           | Triggers `gh-update.service` hourly                     |
| `gh-update-notify@.service` | Email notification, called by `OnSuccess=`/`OnFailure=` |

## What Happens

1. Timer triggers `gh-update.service` every hour.
2. Script checks if new OSM data is available; exits silently if not.
3. If yes, downloads the extract (resuming a partial one) and verifies its checksum.
4. Imports the data into the inactive instance (`a` or `b`).
5. Starts the new instance via systemd and polls until it is healthy.
6. Switches nginx to the new instance and stops the old one.
7. On success: `gh-update-notify@success.service` sends a notification email.

## Failure Handling

Failures are split into two kinds, because the mirror being briefly unreachable
is not the same as a broken import.

**Recoverable** — anything network-shaped: the checksum probe or the download
failing, the mirror serving an error page instead of a checksum, a corrupt
download. `wget` already retries these a few times within the run; if they still
fail, the run ends quietly with `run/result=retry`, **leaving the timer armed**
so the next hourly run tries again. A partially downloaded `.pbf` is kept and
resumed. Only after `NOTIFY_AFTER_FAILURES` (6) consecutive such runs does the
script exit non-zero to trigger an email, and it repeats every 6 runs after
that — the timer still keeps running.

**Hard** — `osmium extract` failing, the GraphHopper import failing, the new
instance never becoming healthy, any of the systemd/nginx switchover steps
failing, or any unanticipated error. These need a human, so the timer is stopped
to avoid re-running a broken state every hour, and
`gh-update-notify@failure.service` sends an email saying so. A downloaded and
verified `.pbf` is left in place, so the retry after a fix does not re-download
it.

Two cases deliberately cross over from recoverable to hard, because retrying
them hourly costs more than it can ever gain:

- `wget` exiting 3 (local file I/O error — typically a full disk).
- The same remote checksum failing to verify twice in a row. The first mismatch
  is retried once; a second one means the mirror or the disk is broken, not
  unlucky, and a ~35 GB re-download per hour is not a reasonable way to find out.

`gh-notify.sh` decides which email to send from the triggering run's
`run/result.<id>`, treating anything other than `retry` as hard — including a
run that died before it could classify itself.

**Caveat:** stopping the timer only lasts until the next reboot. The unit stays
`enabled`, so it is re-armed at boot and, with `Persistent=true`, fires straight
away — resuming hourly retries of the state that failed. Use
`systemctl disable --now gh-update.timer` if a broken state must survive a
reboot (needs a matching sudoers entry if the script should ever do it itself).

## Setup

### 1. Config file

```bash
cp gh-update.conf.example gh-update.conf
chmod 600 gh-update.conf
# fill in MAILGUN_API_KEY, MAILGUN_DOMAIN, NOTIFY_EMAIL
```

### 2. Sudoers

```
freemap ALL=(root) NOPASSWD: /bin/systemctl reload nginx, \
  /bin/systemctl enable --now graphhopper@a, /bin/systemctl enable --now graphhopper@b, \
  /bin/systemctl disable --now graphhopper@a, /bin/systemctl disable --now graphhopper@b, \
  /bin/systemctl stop gh-update.timer, /bin/systemctl start gh-update.timer
```

### 3. Install and enable units

```bash
cp graphhopper@.service gh-update.service gh-update.timer gh-update-notify@.service \
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

The timer is stopped automatically, preventing retries until the issue is fixed.
Check with `systemctl is-active gh-update.timer` (or `systemctl list-timers
--all gh-update.timer` — without `--all` a stopped timer is not listed at all,
so an empty table means disarmed, not "no such timer"). After fixing:

```bash
systemctl reset-failed gh-update.service     # clear the failed state
systemctl start gh-update.timer              # re-enable hourly runs
systemctl start --no-block gh-update.service # optional: trigger immediately
```

`gh-update.service` is `Type=oneshot`, so `systemctl start` blocks until the
whole update finishes (downloading the OSM extract + importing can take a long
time). Use `--no-block` to return immediately and let it run in the background;
follow progress with `journalctl -fu gh-update.service`.
