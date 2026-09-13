# Woow_podman_homeassistant

Home Assistant Core as **rootless Podman Quadlet units driven by systemd**, for a single Linux
host. One command installs it, one upgrades it with an automatic rollback, and an existing
hand-made deployment can be adopted in place.

**[中文版 README](README_zh-TW.md)**

- Rootless podman 4.9.3 (Ubuntu 24.04's version), user systemd with linger, no root daemon
- Host networking, so mDNS/SSDP discovery, the HomeKit bridge and a same-host reverse proxy work
- SQLite recorder in the config dir by default; PostgreSQL and a Matter server are optional
- The image version is pinned in this repo and is the source of truth
- Per-host settings live in `~/.config/homeassistant/homeassistant.env` (mode 0600), never in git

> **Compose users:** this repo was a Docker/Podman Compose stack until v1. The last compose
> version is the tag [`compose-final`](https://github.com/WOOWTECH/Woow_podman_homeassistant/tree/compose-final).
> For plain Docker, follow [upstream's container instructions](https://www.home-assistant.io/installation/linux#docker-compose).
> To adopt an existing container here, see [Migrating an existing deployment](#migrating-an-existing-deployment).

---

## Sister repositories

| Platform | Repository | Format |
|----------|------------|--------|
| **Podman + systemd** (this repo) | [Woow_podman_homeassistant](https://github.com/WOOWTECH/Woow_podman_homeassistant) | Quadlet units |
| **K3s / Kubernetes** | [Woow_k3s_homeassistant](https://github.com/WOOWTECH/Woow_k3s_homeassistant) | Helm chart |

Home Assistant is itself the smart-home operating system, so there is no Home Assistant add-on
variant of this stack.

---

## Table of contents

- [Requirements](#requirements)
- [Install](#install)
- [What gets installed](#what-gets-installed)
- [Settings](#settings)
- [Day-2 operations](#day-2-operations) — [upgrade](#upgrade), [backup](#backup),
  [restore](#restore), [uninstall](#uninstall)
- [Optional components](#optional-components)
- [Migrating an existing deployment](#migrating-an-existing-deployment)
- [Security](#security)
- [Reverse proxy and remote access](#reverse-proxy-and-remote-access)
- [Troubleshooting](#troubleshooting)
- [Tests and CI](#tests-and-ci)

---

## Requirements

| | |
|---|---|
| OS | Ubuntu 24.04 (or any distro with systemd 254+) |
| Podman | 4.9.3 or newer, **rootless** |
| systemd | user manager with **linger** enabled for your user |
| Disk | about 4 GB for the image, plus your config dir |
| Ports | 8123 free on the host (host networking); 21064 and 9584 if you use HomeKit / HA-MCP |

`scripts/install.sh` checks the podman version, enables `loginctl enable-linger` and starts
`podman.socket` for you if they are missing. Do **not** run any script with `sudo`: everything is
rootless and files must stay owned by your user.

---

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_homeassistant.git
cd Woow_podman_homeassistant

# 1. first run: creates ~/.config/homeassistant/homeassistant.env and stops for review
scripts/install.sh

# 2. edit the settings (at minimum HA_CONFIG_DIR and your Zigbee stick)
${EDITOR:-nano} ~/.config/homeassistant/homeassistant.env

# 3. install for real: renders the units, dry-runs them, pulls the image, starts HA
scripts/install.sh
```

The last step ends with `tests/smoke.sh`, which waits for Home Assistant to answer and reports
what it found. Then open `http://<host>:8123` and complete onboarding.

Keep the checkout: `scripts/upgrade.sh`, the optional backup timer and every other script run
from it. Re-run `scripts/install.sh` after every change to the settings file — it is idempotent
and restarts only the units whose files actually changed.

Useful flags (`scripts/install.sh --help` lists them all):

| Flag | Effect |
|---|---|
| `--dry-run` | render, validate and report what would change; touch nothing |
| `--no-start` | install the files and `daemon-reload` only |
| `--no-smoke` | skip the checks at the end |
| `--with-matter` / `--without-matter` | add or remove the optional Matter server |
| `--with-postgres` / `--without-postgres` | add or remove the optional PostgreSQL recorder |
| `--with-backup-timer` / `--without-backup-timer` | add or remove the daily hot backup timer |

The `--with…` / `--without…` choices are saved in the settings file, so a plain re-run keeps
them. Deselecting a component stops and removes its units but **keeps its data**.

---

## What gets installed

| File | Installed to | Unit |
|---|---|---|
| `quadlet/homeassistant.container` | `~/.config/containers/systemd/` | `homeassistant.service` |
| `quadlet/optional/homeassistant-matter.container` + `…-matter-data.volume` | same | `homeassistant-matter.service` |
| `quadlet/optional/homeassistant-db.container` + `…-db-data.volume` + `homeassistant.network` | same | `homeassistant-db.service` |
| `systemd/homeassistant-backup.{service,timer}` | `~/.config/systemd/user/` | `homeassistant-backup.timer` |

The units are rendered at install time: `@@VAR@@` placeholders are replaced with your values, so
the installed unit shows exactly what runs. `~/.local/state/woow-quadlet/homeassistant/manifest`
records what this repo installed, which is how uninstall and backup know what is theirs.

Home Assistant itself:

- `ContainerName=homeassistant`, `Network=host`, `Restart=always`, journald logging
- `Volume=<HA_CONFIG_DIR>:/config:rw` — your config dir is bind-mounted, files stay yours
- `--stop-timeout=300`, because the image gives HA 240 s of s6 grace time on shutdown
- an HTTP health check on `127.0.0.1:<HA_PORT>/manifest.json`; five failures 60 s apart after a
  10 minute start period kill the container and systemd restarts it
- an `ExecStartPre` that waits up to 120 s for DNS, because custom components that pip-install
  their requirements on start (such as HA-MCP) need name resolution

Everyday commands:

```bash
systemctl --user status homeassistant.service
systemctl --user restart homeassistant.service
journalctl --user -u homeassistant.service -f
tests/smoke.sh                 # health and parity checks, exit 0 pass / 1 critical / 2 degraded
```

> Home Assistant's own `homeassistant.stop` service now brings HA back up: the unit has
> `Restart=always`. Stop it with `systemctl --user stop homeassistant.service`.

---

## Settings

`~/.config/homeassistant/homeassistant.env`, one `KEY=value` per line, no quotes, no spaces
around `=`, no comment after a value. `%h` means your home directory.

| Key | Default | Meaning |
|---|---|---|
| `HA_CONFIG_DIR` | `%h/homeassistant/config` | config dir bind-mounted at `/config`; point it at an existing dir to adopt it |
| `HA_PORT` | `8123` | the port HA listens on |
| `HA_PRIVILEGED` | `true` | `--privileged` (upstream parity) or `false` + `--group-add=keep-groups` |
| `HA_ZIGBEE_DEVICE` | *(empty)* | radio as its stable `/dev/serial/by-id/…` path |
| `HA_ZIGBEE_TARGET` | `/dev/ttyACM0` | the path HA sees inside the container |
| `HA_EXTRA_DEVICES` | *(empty)* | more devices, space separated, `host[:container[:perms]]` |
| `HA_TZ` | `local` | `local` follows the host, an IANA name pins it, empty = UTC |
| `HA_BLUETOOTH` | `false` | `true` mounts `/run/dbus` read-only for BlueZ |
| `HA_MATTER` | `false` | optional Matter server |
| `HA_MATTER_LISTEN_ADDRESS` | `127.0.0.1` | the Matter API has no authentication — keep it on loopback |
| `HA_POSTGRES` | `false` | optional PostgreSQL recorder |
| `HA_DB_PORT` | `15432` | loopback port the database is published on |
| `HA_BACKUP_TIMER` | `false` | optional daily hot backup |
| `HA_BACKUP_DIR` | `%h/backups/homeassistant` | where backups are written |
| `HA_BACKUP_KEEP` | `5` | how many `ha-hot-*` / `ha-cold-*` backups to keep |

Hardware settings are explained in [docs/hardware.md](docs/hardware.md) — read it before setting
`HA_PRIVILEGED=false` or changing the Zigbee paths.

---

## Day-2 operations

### Upgrade

The repo pins the version. Upgrading means getting a newer checkout and running the script:

```bash
git pull                # or: git checkout v1.1.0
scripts/upgrade.sh
```

It refuses to go backwards, and it always: checks that HA is healthy now → takes a snapshot for
comparison → dry-runs the new units and pulls the new image **while HA keeps running** → stops HA
gracefully → takes a **cold backup** → installs and starts the new version → compares against the
snapshot. A critical failure rolls back on its own (stop, restore the config dir from the cold
backup, reinstall the saved unit files, start, re-check) and exits 1. Degraded checks alone never
roll back; they exit 2.

```bash
scripts/upgrade.sh --rollback        # by hand, back to the newest pre-upgrade backup
```

The previous image stays on disk, so a rollback needs no download. After a rollback, check out
the matching older tag of this repo before running `install.sh` again.

### Backup

```bash
scripts/backup.sh                 # hot if HA is running, else cold
scripts/backup.sh --hot           # HA keeps running
scripts/backup.sh --cold --stop   # stop HA, copy everything, start it again
scripts/install.sh --with-backup-timer    # daily hot backup at 03:30
```

A backup is a `0700` directory under `HA_BACKUP_DIR` holding `config.tgz`, `sqlite/*.db.gz`
(hot backups: the SQLite databases are copied with SQLite's online backup API inside the
container and verified with `PRAGMA quick_check`), the Matter volume and the Postgres dump when
those are installed, the installed unit files, your settings file, `manifest.env` and
`SHA256SUMS`. The newest `HA_BACKUP_KEEP` hot and cold backups are kept; backups written by
`upgrade.sh`, `migrate-legacy.sh` and `--dest` are never pruned.

### Restore

```bash
scripts/restore.sh ~/backups/homeassistant/ha-cold-20260912-0300
scripts/restore.sh <dir> --with-unit      # also put back the HA version the backup came from
scripts/restore.sh <dir> --config-only    # the config dir only, nothing started
```

It verifies `SHA256SUMS` first, stops HA, unpacks next to the current config dir and only then
swaps them — the previous config dir is kept as `<config dir>.pre-restore-<timestamp>`. Home
Assistant cannot run an older version on a config a newer version has migrated, so restoring an
older backup needs `--with-unit` (go back to that version) or `--forward` (let the installed
version migrate it, one-way). The script refuses rather than guessing.

### Uninstall

```bash
scripts/uninstall.sh                  # stop and remove the units; all data is kept
scripts/uninstall.sh --dry-run --purge
scripts/uninstall.sh --purge --yes    # also delete the volumes, network, secret and images
scripts/uninstall.sh --purge --yes --delete-config=/exact/path/to/config
```

`--purge` is the only way this repo deletes data, it exports the volumes to
`$HA_BACKUP_DIR/ha-pre-purge-<timestamp>/` first, and `--delete-config` must name the configured
`HA_CONFIG_DIR` exactly. The settings file and the backup directory are never deleted.

---

## Optional components

| Component | Enable | Docs |
|---|---|---|
| Matter server (matter.js 1.4.0) | `scripts/install.sh --with-matter` | [docs/matter.md](docs/matter.md) |
| PostgreSQL recorder | `scripts/install.sh --with-postgres` | [docs/postgres.md](docs/postgres.md) |
| Daily hot backup | `scripts/install.sh --with-backup-timer` | [Backup](#backup) |

Both optional containers are off by default: SQLite in the config dir is the right recorder for
most installs, and Home Assistant does not migrate SQLite history into PostgreSQL.

---

## Migrating an existing deployment

If a container named `homeassistant` already exists and Quadlet does not manage it,
`scripts/install.sh` **refuses to run**. That is deliberate: Quadlet starts HA with
`podman run --replace`, which would delete that container and its writable layer.

```bash
scripts/migrate-legacy.sh --dry-run     # report only; changes nothing
scripts/migrate-legacy.sh               # migrate, with a cold backup and a rollback
scripts/migrate-legacy.sh --rollback    # put the legacy deployment back
```

The script derives the settings from `podman inspect` (the `/config` bind, `--privileged`, the
devices from the CreateCommand, the time zone, `/run/dbus`), refuses a non-host network, mounts
the new unit would not carry and an HA version other than this checkout's pin, takes a pre-flight
snapshot, stops the legacy deployment gracefully, backs it up cold, disables the legacy unit
(the file is kept) and retires the legacy container before installing — renamed to
`<name>-legacy-<timestamp>` and left stopped, or, where `podman-restart.service` would revive
such a copy at the next boot, captured into the backup and removed
([which shape, and why](docs/migrating.md#which-rollback-shape)). It then compares the result with the snapshot and rolls back automatically if a
critical check fails. Everything is recorded under `$HA_BACKUP_DIR/ha-pre-quadlet-<timestamp>/`.

Full walkthrough, including the token the comparison needs and the cleanup after the soak:
[docs/migrating.md](docs/migrating.md).

---

## Security

- **Nothing secret is in the repo or in a unit file.** The PostgreSQL password is a podman
  secret (`homeassistant-db-password`) generated by `install.sh` from 48 random characters.
  `~/.config/homeassistant/homeassistant.env` is created mode 0600 and holds settings only.
- **Rootless.** Every container runs as your user in a user namespace; no script needs `sudo`.
  The Matter container additionally runs with `NoNewPrivileges=true` and `DropCapability=ALL`.
- **Loopback by default.** The optional database publishes on `127.0.0.1` only, and the Matter
  WebSocket API — which has **no authentication** — binds `127.0.0.1` unless you change
  `HA_MATTER_LISTEN_ADDRESS`.
- **Port 8123 is not authenticated at the network layer.** Home Assistant has its own login, but
  do not expose it directly; put it behind a Cloudflare tunnel or a reverse proxy with TLS.
- **`HA_PRIVILEGED=true` is upstream parity, not a security boundary.** It makes every host
  device visible to the container. `HA_PRIVILEGED=false` passes only the devices you list;
  see [docs/hardware.md](docs/hardware.md) for what it costs.
- **Backups contain everything**, including `.storage` with HA's tokens and integration
  credentials. They are written mode 0700/0600 under `HA_BACKUP_DIR`; treat that directory like
  the config dir itself.
- The smoke-test token, if you use one, lives in `~/.config/homeassistant/smoke.header`
  (mode 0600) and is only read by `tests/smoke.sh`.

---

## Reverse proxy and remote access

Home Assistant runs on the host network, so a reverse proxy or a Cloudflare tunnel on the same
host reaches it at `localhost:8123`. Home Assistant needs to be told to trust it:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
```

Check the result with `tests/smoke.sh --public-url https://ha.example.com`: `/manifest.json` must
answer 200 and `/api/` must answer **401**. A **400** means `trusted_proxies` is wrong. Details
and the Nginx Proxy Manager variant: [docs/reverse-proxy.md](docs/reverse-proxy.md).

---

## Troubleshooting

```bash
systemctl --user status homeassistant.service
journalctl --user -u homeassistant.service -n 200 --no-pager
podman healthcheck run homeassistant          # run the health check by hand
podman logs --tail 100 homeassistant
tests/smoke.sh --wait 900                     # wait for HA, then report every check
scripts/install.sh --dry-run                  # what would change, without changing it
```

| Symptom | Likely cause |
|---|---|
| `install.sh` refuses: legacy container | a hand-made `homeassistant` container exists → [migrate](#migrating-an-existing-deployment) |
| `install.sh` refuses: port in use | something else holds 8123 (host networking means HA cannot share it) |
| `install.sh` refuses: device mismatch | with `HA_PRIVILEGED=true` the by-id link must resolve to `HA_ZIGBEE_TARGET` ([docs/hardware.md](docs/hardware.md)) |
| ZHA cannot open the radio | the old process still holds it, or the host node was renumbered after a reboot |
| HA restarts in a loop | the health check is failing; read the journal, then `tests/smoke.sh` |
| Units do not survive a reboot | linger is off: `loginctl enable-linger $USER` |

---

## Tests and CI

```bash
tests/dryrun.sh          # render every variant, run the real Quadlet generator + systemd-analyze
tests/scripts-test.sh    # end-to-end tests of scripts/*.sh against podman/systemctl doubles
tests/smoke.sh           # health and parity checks against a running deployment
shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh
```

`tests/dryrun.sh` and `tests/scripts-test.sh` never create a container and never touch your real
user manager. GitHub Actions runs them on `ubuntu-24.04`, which ships the same podman 4.9.3 as
the target hosts, together with shellcheck and a check that the vendored
`scripts/lib/quadlet-lib.sh` is unmodified.

---

## License

MIT. See [LICENSE](LICENSE).
