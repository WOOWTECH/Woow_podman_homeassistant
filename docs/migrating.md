# Migrating an existing deployment

`scripts/migrate-legacy.sh` adopts a Home Assistant container you created by hand
(`podman run` / `podman create` plus a hand-written systemd user unit) into the Quadlet
deployment, **in place**, on the same config dir, with a recorded rollback.

Back to [README](../README.md).

## Why you cannot just run install.sh

Quadlet starts Home Assistant with `podman run --replace --name homeassistant`. If a container of
that name already exists and Quadlet does not own it, that container **and its writable layer are
deleted** on the first start. On a hand-made deployment that layer is not disposable: it holds,
for example, the packages a custom component pip-installs at runtime.

`scripts/install.sh` therefore refuses to run while a container named `homeassistant` exists
without the label `PODMAN_SYSTEMD_UNIT=homeassistant.service`, while a hand-written user unit that
starts or stops it is active or enabled, or while another running container bind-mounts your
`HA_CONFIG_DIR`. It prints the rename command and points you here.

## Before you start

- **Same version.** This repo pins the version in `quadlet/homeassistant.container`, and the
  migration refuses to run when the legacy image's `io.hass.version` label differs: check out the
  repo tag that matches what you run today, migrate, then upgrade. A migration is not an upgrade.
- **Host networking.** The legacy container must be on `--network host`; a bridge deployment needs
  a manual migration.
- **A long-lived token**, so the before/after comparison can read the API. Create one on the Home
  Assistant profile page and store it as a curl header file (without it the config-entry and
  entity comparisons are skipped, and the report says so):

  ```bash
  install -d -m 700 ~/.config/homeassistant
  printf 'Authorization: Bearer %s\n' '<token>' > ~/.config/homeassistant/smoke.header
  chmod 600 ~/.config/homeassistant/smoke.header
  ```
- **A second terminal** into the host that does not depend on Home Assistant.

## Dry run first

```bash
scripts/migrate-legacy.sh --dry-run [--public-url https://ha.example.com]
```

A dry run changes nothing. It prints the settings it derived, the version gate result and a
pre-flight snapshot summary. Read the derived settings before going ahead.

Options:

```
--container NAME      the legacy container (default: homeassistant)
--legacy-unit UNIT    the unit that runs it, repeatable. Default: every
                      ~/.config/systemd/user/*.service whose Exec lines name the container
--public-url URL      also check the public route before and after
--allow-unhealthy     migrate although the legacy instance fails its pre-flight checks
--no-auto-rollback    keep the Quadlet deployment when the post-check fails critically
```

### What it derives from `podman inspect`

| Legacy | Setting |
|---|---|
| `/config` bind source | `HA_CONFIG_DIR` (with `$HOME` rewritten to `%h`) |
| `--privileged` | `HA_PRIVILEGED` |
| `--device` in `.Config.CreateCommand` | `HA_ZIGBEE_DEVICE` / `HA_ZIGBEE_TARGET`, `HA_EXTRA_DEVICES` |
| `TZ` environment | `HA_TZ` (none gives UTC, as before) |
| `/run/dbus` mount | `HA_BLUETOOTH` |

Devices come from the recorded `CreateCommand`, not from `HostConfig.Devices`, because podman
empties that field under `--privileged` (see [docs/hardware.md](hardware.md)).

It refuses a network mode other than `host`, a mount the Quadlet unit would not carry (an extra
`-v /srv/media:/media`, say), and a Home Assistant version other than this checkout's pin.

## The migration

```bash
scripts/migrate-legacy.sh --yes --public-url https://ha.example.com
```

Home Assistant is down for roughly five minutes. The recorded steps:

1. discover the container and its units, derive the settings
2. render and dry-run the new unit; pull the pinned image while Home Assistant still runs
3. pre-flight snapshot (`tests/smoke.sh --legacy --snapshot`): registry counts, ports 8123 / 9584 /
   21064, `manifest.json`, log ERROR signatures, and with a token the API state and entries
4. graceful stop: the legacy unit, then `podman stop -t 300`; wait until the container, the port
   and the radio are free
5. cold backup of the config dir (`scripts/backup.sh --cold`)
6. disable the legacy unit (**the file is kept**) and retire the container, so Quadlet's
   `podman run --replace` cannot delete it: renamed to `<name>-legacy-<ts>` and left stopped,
   or — see [Which rollback shape](#which-rollback-shape) — captured and removed
7. write `~/.config/homeassistant/homeassistant.env` and run `scripts/install.sh`
8. post-check: `tests/smoke.sh --compare` against the snapshot

A critical post-check failure rolls the migration back automatically, unless you passed
`--no-auto-rollback`. Degraded checks keep the migration and exit 2.

## The record

Everything lands in `$HA_BACKUP_DIR/ha-pre-quadlet-<ts>/` (0700):

```
migration.env     TS, container, STRATEGY, renamed container, units, STATUS
                  (started -> done|rolled-back)
derived.env       the settings it derived          preflight.json  the before snapshot
migrate.log       the full run                     backup/         the cold backup
legacy/           inspect.json, createcommand.json and a copy of each legacy unit file
legacy-container/<name>/   on the capture path only: everything ql_recreate_container needs
```

## Which rollback shape

Renaming the legacy container and leaving it stopped is a rollback path only while nothing
starts it again. The user unit `podman-restart.service` runs
`podman start --all --filter restart-policy=always` at boot, so on a host where that unit is
**enabled** a renamed, stopped container whose restart policy is exactly `always` revives at the
next boot — and then two Home Assistants fight over the name `homeassistant`, port 8123, the
Zigbee radio and the same SQLite recorder database. podman 4.9.3 cannot repair that afterwards:
`podman update` only rewrites cgroup limits, and a restart policy is fixed at create time.

Step 1 therefore asks `ql_rollback_strategy`, which reads this host's real state — is that unit
enabled, what is this container's policy — and never its host name. `--dry-run` prints which
path applies, and `migration.env` records the one that was used.

| Answer | When | Step 6 does | `--rollback` does |
|---|---|---|---|
| `rename` | the unit is disabled, or the container's policy is not `always` | `podman rename <name> <name>-legacy-<ts>`, left stopped | renames it back |
| `capture` | the unit is enabled **and** the container's policy is `always` | writes `legacy-container/<name>/` (inspect, create command, image, policy, mounts, networks) and then a plain `podman rm` — never `podman rm -v`, which would delete the anonymous volumes | `ql_recreate_container` recreates it stopped, with its original restart policy |

The capture uses `ql_capture_container --commit`. Home Assistant pip-installs the requirements
of every configured integration into `/usr/local` **inside its own container**: the live
`woowtechopenclaw` container carries about 48 MB and ~2900 files there. `--commit` puts that
writable layer into a local image first, so a rollback starts from what actually ran instead of
from a bare image that has to re-install every dependency before HA comes up. What still does
not survive is the container id and the IP/MAC lease; the `/config` bind mount is untouched
either way.

A container created through the podman API rather than the CLI (docker-compose over the podman
socket, `podman play`) records no create command, so there is nothing to replay. On a host that
needs the capture path the migration refuses in step 1, while Home Assistant is still running,
rather than discovering it after the stop.

Today `homeassistant` is `unless-stopped` on `woowtechopenclaw` and `podman-restart.service` is
disabled on `toypark1234`, so both hosts take the `rename` path. The capture path exists because
a policy can change and the script can be run on another host.

## Rolling back

```bash
scripts/migrate-legacy.sh --rollback --yes                  # the newest migration
scripts/migrate-legacy.sh --rollback 20260912-013000 --yes  # a specific one
```

It stops and removes the Quadlet unit, brings the legacy container back (renamed back, or
recreated from the capture — whichever shape the migration used), re-enables and starts its
unit, and compares against the pre-flight snapshot. No data restore is involved: the same
version runs on the same config dir, so nothing recorded since the migration is lost.

Only when the config dir itself is damaged:

```bash
scripts/migrate-legacy.sh --rollback --restore-config --yes
```

That puts the pre-migration cold backup back and **loses everything recorded since the
migration**.

**Never start the legacy unit while `homeassistant.service` is active.** Both manage a container
called `homeassistant` and they will fight: the legacy unit's `ExecStartPre=podman stop
homeassistant` would stop the Quadlet container in a loop. You cannot `systemctl --user mask` the
legacy unit either, because its file sits in the directory the mask would write to; it stays
disabled instead.

## After the migration

Soak for about a week before cleaning anything up:

```bash
tests/smoke.sh --compare ~/backups/homeassistant/ha-pre-quadlet-<ts>/preflight.json
systemctl --user show homeassistant.service -p NRestarts
```

Worth testing deliberately during the soak: a controlled `systemctl --user restart
homeassistant.service`, a `podman kill homeassistant` to prove `Restart=always`, and - once you
have a second way into the host - a reboot, which is what the conversion is for.

Only then, and only with the owner's approval, remove the legacy container and move its unit file
out of the way; keep the migration record for a month.

```bash
podman rm homeassistant-legacy-<ts>   # rename path only; the capture path already removed it
mkdir -p ~/backups/homeassistant/legacy-units
mv ~/.config/systemd/user/podman-ha.service* ~/backups/homeassistant/legacy-units/
systemctl --user daemon-reload
```

## See also

- [docs/hardware.md](hardware.md) - radios, Bluetooth, time zone
- [docs/matter.md](matter.md) - replacing a legacy matter-server container
- [docs/reverse-proxy.md](reverse-proxy.md) - the public-route checks used before and after
