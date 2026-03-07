# GraphHopper Update Scripts

These scripts keep GraphHopper routing data up to date using systemd timers and services.

## Scripts

- `gh-update.sh` — downloads OSM data, imports it into the inactive instance, switches nginx to it, stops the old instance.
- `gh-notify.sh` — sends a Mailgun email on success (only when an update was actually performed) or failure.

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
3. If yes, imports data into the inactive instance (`a` or `b`).
4. Starts the new instance via systemd and polls until it is healthy.
5. Switches nginx to the new instance and stops the old one.
6. On success: `gh-update-notify@success.service` sends a notification email.
7. On failure: `gh-update-notify@failure.service` sends a failure email. The service is left in `failed` state — the timer does not retry until the service is explicitly reset.

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

## After a Failure

On failure the timer is stopped automatically, preventing retries until the issue is fixed. After fixing:

```bash
systemctl start gh-update.timer     # re-enable hourly runs
systemctl start gh-update.service   # optional: trigger immediately
```
