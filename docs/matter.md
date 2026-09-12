# Matter server (optional)

Home Assistant's Matter integration does not speak Matter itself: it connects to a Matter
controller over a WebSocket API. This repo ships that controller as an optional unit.

Back to [README](../README.md).

## Install and remove

```bash
scripts/install.sh --with-matter        # sets HA_MATTER=true and installs the unit
scripts/install.sh --without-matter     # sets HA_MATTER=false, stops and removes the unit
```

The choice is saved in `~/.config/homeassistant/homeassistant.env`, so a later plain
`scripts/install.sh` keeps it. Selecting Matter installs two files:

- `homeassistant-matter.container` - `ghcr.io/matter-js/matterjs-server:1.4.0`, container name
  `homeassistant-matter`
- `homeassistant-matter-data.volume` - `VolumeName=homeassistant-matter-data`, so the volume name
  is stable and an existing volume of that name is adopted instead of a new
  `systemd-homeassistant-matter-data` being created

Removing the unit with `--without-matter` **keeps the volume and its fabric data**. Only
`scripts/uninstall.sh --purge` deletes it, after a final export.

Then add the Matter integration in Home Assistant and point it at `ws://localhost:5580/ws`.

## Why matter.js

`python-matter-server` is archived upstream; matter.js server is its successor and serves the
same WebSocket API on the same port, so an existing Home Assistant Matter config entry keeps
working. The upstream project describes the container image as provided as-is.

## Listen address

```ini
HA_MATTER_LISTEN_ADDRESS=127.0.0.1   # default
HA_MATTER_LISTEN_ADDRESS=            # empty: listen on every interface
```

The WebSocket API and the built-in dashboard have **no authentication**. Only Home Assistant on
this host needs them, so the default binds them to loopback.

Edge case: with `127.0.0.1` set, a Matter config entry whose URL is `ws://localhost:5580/ws` can
fail when Home Assistant resolves `localhost` to `::1` first. Either change the entry URL to
`ws://127.0.0.1:5580/ws`, or leave `HA_MATTER_LISTEN_ADDRESS` empty and protect the port with the
host firewall.

## Networking and user namespace

The unit uses `Network=host`, like Home Assistant itself: Matter commissioning needs the host's
IPv6 link-local addresses and mDNS on the real interfaces. It cannot work behind a bridge network.

The image runs as `USER 1000:1000`, so the unit sets `UserNS=keep-id:uid=1000,gid=1000`. That maps
your host user onto container uid 1000 and keeps the volume owned by you whatever your host uid
is. The unit also drops all capabilities and sets `NoNewPrivileges=true`.

## Taking over data from python-matter-server

matter.js migrates python-matter-server storage on its first start, but only if the data is in
the volume before that first start. Seed the volume, then install:

```bash
# 1. export the old data: a named or anonymous volume ...
podman volume export <old-volume> > ~/matter-legacy.tar
# ... or a bind directory
tar -C ~/matter-server-data -cf ~/matter-legacy.tar .

# 2. create the volume under the name the unit expects, and load the data into it
podman volume create homeassistant-matter-data
podman volume import homeassistant-matter-data ~/matter-legacy.tar

# 3. check the files belong to you inside the user namespace
podman unshare ls -ln "$(podman volume inspect --format '{{.Mountpoint}}' homeassistant-matter-data)"

# 4. install; the unit adopts the existing volume
scripts/install.sh --with-matter
```

If step 3 shows foreign ownership, fix it with
`podman unshare chown -R 0:0 "$(podman volume inspect --format '{{.Mountpoint}}' homeassistant-matter-data)"`
before starting.

## Replacing a legacy matter-server container

Never run the old and the new controller at the same time: both want TCP 5580, and two
controllers on one fabric will fight.

```bash
TSB=$(date +%Y%m%d-%H%M%S)
podman stop -t 30 matter-server
systemctl --user stop podman-matter-server.service
systemctl --user disable podman-matter-server.service        # keep the file for rollback
podman rename matter-server matter-server-legacy-$TSB        # stopped, kept for rollback
scripts/install.sh --with-matter
```

Installing Matter does not change `homeassistant.container`, so Home Assistant is not restarted.

Roll back with `scripts/install.sh --without-matter` (it stops and removes the unit and keeps the
volume), then rename the legacy container back and enable and start its unit again.

## Checks

```bash
ss -ltnp | grep ':5580 '                                     # expect 127.0.0.1:5580
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5580/   # expect 200
systemctl --user status homeassistant-matter.service
journalctl --user -u homeassistant-matter.service -n 100
```

`tests/smoke.sh` reports the Matter port and the Matter config entry as degraded-class checks when
`HA_MATTER=true`.

## See also

- [docs/hardware.md](hardware.md) - radios, Bluetooth, time zone
- [docs/postgres.md](postgres.md) - the optional PostgreSQL recorder
- [docs/migrating.md](migrating.md) - adopting an existing hand-made deployment
