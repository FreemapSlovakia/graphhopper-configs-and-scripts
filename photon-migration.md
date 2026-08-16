# Migrating Photon to the a/b updater

One-time steps to go from the hand-built single instance to the blue/green
setup driven by `photon-update.sh`.

**The running geocoder is never stopped.** Every step below either touches
files nothing has open yet, or changes systemd/nginx bookkeeping that does not
affect a running process. The only cutover is the ordinary nginx flip at the
end of the first update, after the new index has been health-checked — the same
switch that happens on every later update.

Two steps are dangerous if skipped or reordered; they are marked **⚠**.

Run everything as `freemap` unless it says `sudo`.

---

## 1. Keep nginx valid across the checkout ⚠

The tracked `photon.freemap.sk` replaces the hardcoded `proxy_pass` with
`include /opt/photon/photon-upstream.conf;`. That file must exist *before* the
checkout lands, or any nginx reload in between fails — and reloads happen on
their own: certbot renewals, and the GraphHopper updater at the end of every
run.

```bash
printf 'proxy_pass http://127.0.0.1:2322/;\n' | sudo -u freemap tee /opt/photon/photon-upstream.conf
```

## 2. Turn /opt/photon into a checkout

`photon.freemap.sk` already exists and collides with the tracked file, so move
it out of the way first (`photon.freemap.sk.hardened` is a byte-identical copy
that stays behind as a backup).

```bash
sudo -u freemap mv /opt/photon/photon.freemap.sk /fm/data4/martin/photon-install/photon.freemap.sk.pre-git

cd /opt/photon
sudo -u freemap git init -b main
sudo -u freemap git remote add origin https://github.com/FreemapSlovakia/graphhopper-configs-and-scripts.git
sudo -u freemap git fetch origin
sudo -u freemap git reset --hard origin/main
sudo -u freemap git branch --set-upstream-to=origin/main main
```

`git reset --hard` overwrites tracked files only; the jars and the other
untracked files are left alone. Check nginx is still happy and that the
switchover file is now the real one:

```bash
sudo nginx -t
ls -l /opt/photon/photon-upstream.conf     # still the plain file from step 1
diff /fm/data4/martin/photon-install/photon.freemap.sk.pre-git /opt/photon/photon.freemap.sk
# should differ only in the proxy_pass -> include swap
```

Now make it the symlink the update script flips:

```bash
sudo -u freemap ln -sfn ./photon-upstream.a.conf /opt/photon/photon-upstream.conf
sudo nginx -t && sudo systemctl reload nginx
```

Both point at 2322, so this reload changes nothing that a client can see.

## 3. Data directory symlinks

The live index stays exactly where it is; side `a` just points at it.

```bash
sudo -u freemap ln -s /fm/data4/photon   /opt/photon/photon-data.a
sudo -u freemap mkdir -p /fm/data4/photon-b
sudo -u freemap ln -s /fm/data4/photon-b /opt/photon/photon-data.b
```

The real paths are asymmetric (`photon` vs `photon-b`) because renaming a
directory out from under the running JVM is not worth the risk. The symlink
indirection is exactly what makes the real name irrelevant. If it bothers you,
rename it once side `a` is idle — see step 8.

## 4. Config

Copies the Mailgun credentials across without printing them:

```bash
sudo -u freemap bash -c '
  { grep -vE "^(MAILGUN_|NOTIFY_EMAIL)" /opt/photon/photon-update.conf.example
    grep -E  "^(MAILGUN_|NOTIFY_EMAIL)" /opt/graphhopper/gh-update.conf
  } > /opt/photon/photon-update.conf
  chmod 600 /opt/photon/photon-update.conf'

sudo -u freemap grep -vE "MAILGUN_API_KEY" /opt/photon/photon-update.conf   # sanity check
```

## 5. Units ⚠

```bash
sudo cp /opt/photon/photon@.service /opt/photon/photon-update.service \
        /opt/photon/photon-update.timer /opt/photon/photon-update-abort.service \
        /etc/systemd/system/
sudo systemctl daemon-reload

sudo systemctl disable photon.service     # leaves the running process alone
sudo systemctl enable  photon@a           # marks a as active; does NOT start it
```

Neither command touches the running process — `disable` and `enable` only
manage boot-time symlinks. After them a reboot would start `photon@a` on 2322
against the same index, which is the state we want anyway.

**`enable photon@a` is not optional.** The update script picks the idle side by
asking `systemctl is-enabled photon@a`. With neither instance enabled it
resolves the active side to `none` and treats **`a` as the target to import
into** — and `a` is the live index, which it would `rm -rf` before importing.

Verify before going further:

```bash
systemctl is-enabled photon@a       # enabled
systemctl is-active  photon.service # active — still serving on 2322
```

## 6. Sudoers

Add the Photon lines to the existing `freemap` rule:

```
  /bin/systemctl enable --now photon@a, /bin/systemctl enable --now photon@b, \
  /bin/systemctl disable --now photon@a, /bin/systemctl disable --now photon@b
```

Check it took, since `sudo -n` failing mid-update is a hard failure:

```bash
sudo -u freemap sudo -n -l | grep photon
```

## 7. First run, by hand

Do not enable the timer yet — watch one run first.

```bash
sudo systemctl start --no-block photon-update.service
journalctl -fu photon-update.service
```

Roughly: a 13 GB download, an md5 verify, then ~7 hours of import, then
`photon@b` starts on 2323, gets polled until it answers a real geocoding query,
nginx flips to it, the proxy cache is purged, and you get an email.

Peak usage during the run: ~131 GB disk (59 GB live + ~59 GB new + 13 GB dump)
and ~32 GB RAM across the three JVMs. Both are comfortable here.

If it fails it writes `/opt/photon/run/halted` with the reason and mails you;
nothing switches over, and the live index is untouched.

## 8. Retire the old service ⚠

Once traffic is on `b`, stop the process that step 5 orphaned:

```bash
sudo systemctl stop photon.service
sudo rm /etc/systemd/system/photon.service
sudo systemctl daemon-reload
```

**Do this before the next update runs.** That run imports into side `a` —
`/fm/data4/photon` — and clears the directory first. Doing that while the old
process still has the index open leaves it serving from deleted inodes.

Optional tidy-up now that side `a` is idle:

```bash
sudo -u freemap mv /fm/data4/photon /fm/data4/photon-a
sudo -u freemap ln -sfn /fm/data4/photon-a /opt/photon/photon-data.a
```

## 9. Enable the schedule

```bash
sudo systemctl enable --now photon-update.timer
systemctl list-timers photon-update.timer
```

---

## Rolling back

Before step 7 nothing has changed for clients, and the old service is still the
one serving. To abandon the migration:

```bash
sudo systemctl enable --now photon.service    # if it somehow stopped
sudo systemctl disable photon@a
sudo -u freemap cp /fm/data4/martin/photon-install/photon.freemap.sk.pre-git /opt/photon/photon.freemap.sk
sudo nginx -t && sudo systemctl reload nginx
```

After step 7, side `a` still holds the old index untouched, so pointing
`photon-upstream.conf` back at `photon-upstream.a.conf` and starting
`photon@a` returns you to the previous data.

## Notes

- The jar version appears in two places that must agree: `ExecStart` in
  `photon@.service` and `PHOTON_JAR` in `photon-update.conf`.
- `photon-1.2.1.jar`, the pre-migration `photon.service` and
  `nginx-photon.conf` are gitignored, so they stay put and out of `git status`.
- `nginx-photon.conf` is installed separately at `/etc/nginx/conf.d/`; it holds
  the `limit_req_zone` and `proxy_cache_path` the vhost depends on and is not
  managed by this checkout.
