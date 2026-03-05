# GraphHopper Update Scripts

These scripts keep GraphHopper data up to date with hourly cron.

## Scripts

- `gh-update-root.sh`: run by root from cron.
- `gh-update.sh`: does download, import, and switch between instances.

## What Happens

1. Script checks if new OSM data is available.
2. If yes, it imports data into inactive instance (`a` or `b`).
3. It starts the new instance and waits until it is healthy.
4. It switches nginx to the new instance.
5. It reloads nginx and stops old instance.

If update is already running, next run exits safely.

## Required Setup

- Add sudoers rule for user `freemap`:

```bash
freemap ALL=(root) NOPASSWD: /bin/systemctl reload nginx
```

## Cron (root)

```cron
0 * * * * /opt/graphhopper/gh-update-root.sh
```

## Log

- Main log file: `/opt/graphhopper/gh-update.log`
