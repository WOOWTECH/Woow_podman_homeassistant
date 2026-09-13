# Deployment card — Home Assistant (Podman Quadlet + systemd)

Quick reference. The full documentation is in [README.md](README.md); the Chinese version is
[README_zh-TW.md](README_zh-TW.md).

| | |
|---|---|
| Runtime | rootless podman 4.9.3+, user systemd with linger, Ubuntu 24.04 |
| Image | `ghcr.io/home-assistant/home-assistant` — the exact version is pinned in `quadlet/homeassistant.container` |
| Network | host (mDNS/SSDP discovery, HomeKit bridge, same-host reverse proxy) |
| Recorder | SQLite in the config dir; PostgreSQL optional |
| Settings | `~/.config/homeassistant/homeassistant.env` (0600), rendered into the units at install time |
| Units | `homeassistant.service` (+ optional `homeassistant-matter.service`, `homeassistant-db.service`, `homeassistant-backup.timer`) |
| Data | `HA_CONFIG_DIR` bind mount, `homeassistant-matter-data` and `homeassistant-db-data` volumes |

---

## Pre-flight

```bash
podman --version                       # 4.9.3 or newer
loginctl show-user "$USER" -p Linger   # Linger=yes (install.sh enables it)
ss -lntp 'sport = :8123'               # must be free, unless it is the deployment you are adopting
podman ps --filter name=homeassistant  # a hand-made container here means: migrate, do not install
```

Never run these scripts with `sudo`.

---

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_homeassistant.git
cd Woow_podman_homeassistant
scripts/install.sh                                   # 1. writes the settings file, stops
${EDITOR:-nano} ~/.config/homeassistant/homeassistant.env   # 2. HA_CONFIG_DIR, radio, options
scripts/install.sh                                   # 3. render -> dry-run -> pull -> start -> smoke
```

Keep the checkout in place: upgrades and the backup timer run from it.

---

## Day-2

| Task | Command |
|---|---|
| Status | `systemctl --user status homeassistant.service` |
| Logs | `journalctl --user -u homeassistant.service -f` |
| Restart | `systemctl --user restart homeassistant.service` |
| Stop | `systemctl --user stop homeassistant.service` (HA's own `homeassistant.stop` restarts it) |
| Apply a settings change | `scripts/install.sh` (idempotent; restarts only what changed) |
| Preview a change | `scripts/install.sh --dry-run` |
| Upgrade | `git pull && scripts/upgrade.sh` |
| Roll back an upgrade | `scripts/upgrade.sh --rollback` |
| Backup | `scripts/backup.sh` (`--hot` / `--cold [--stop]`) |
| Restore | `scripts/restore.sh <backup-dir>` (`--with-unit` for another version) |
| Health / parity checks | `tests/smoke.sh` — exit 0 pass, 1 critical, 2 degraded |
| Public route check | `tests/smoke.sh --public-url https://ha.example.com` |
| Uninstall (keep data) | `scripts/uninstall.sh` |
| Uninstall and delete data | `scripts/uninstall.sh --purge --yes` |

## Options

```bash
scripts/install.sh --with-matter          # Matter server, docs/matter.md
scripts/install.sh --with-postgres        # PostgreSQL recorder, docs/postgres.md
scripts/install.sh --with-backup-timer    # daily hot backup at 03:30
```

The choices are saved in the settings file. `--without-…` removes the units and keeps the data.

## Adopting an existing deployment

```bash
scripts/migrate-legacy.sh --dry-run    # report; changes nothing
scripts/migrate-legacy.sh              # snapshot -> stop -> cold backup -> rename -> install -> compare
scripts/migrate-legacy.sh --rollback   # put the legacy deployment back
```

Quadlet starts HA with `podman run --replace`, so a hand-made container of the same name must be
renamed first — that is exactly what this script does. See [docs/migrating.md](docs/migrating.md).

---

## Upgrade sequence (what `upgrade.sh` does)

1. HA must be healthy now (`--force` overrides)
2. `tests/smoke.sh --snapshot` for the later comparison
3. dry-run the new units and pull the new image **while HA still runs**
4. stop HA gracefully (up to 300 s) and take a **cold backup** into `$HA_BACKUP_DIR/ha-pre-upgrade-<ver>-<ts>/`
5. install and start the new version
6. `tests/smoke.sh --compare`; a critical failure restores the cold backup and the old units, then exits 1

## Rollback rules

- After a version change, a rollback **must** restore the config dir: HA cannot run an older
  version on a migrated recorder schema or `.storage`. `upgrade.sh` enforces this.
- After a migration with no version change, a rollback needs no data restore — rename the
  containers back (`scripts/migrate-legacy.sh --rollback`).
- Never start a legacy unit while `homeassistant.service` is active: both would manage a
  container named `homeassistant`.

---

## Files and paths

| Path | Contents |
|---|---|
| `~/.config/homeassistant/homeassistant.env` | per-host settings (0600) |
| `~/.config/homeassistant/smoke.header` | optional long-lived token for the API checks (0600) |
| `~/.config/containers/systemd/` | installed Quadlet units |
| `~/.config/systemd/user/` | installed backup service and timer |
| `~/.local/state/woow-quadlet/homeassistant/manifest` | what this repo installed |
| `$HA_BACKUP_DIR` (`~/backups/homeassistant`) | backups, upgrade and migration records |

## Security notes

- No secret is in the repo or in a unit file; the database password is a podman secret.
- The database publishes on `127.0.0.1` only; the Matter API has no authentication and binds
  `127.0.0.1` by default.
- Do not expose 8123 directly — use a Cloudflare tunnel or a reverse proxy with TLS and set
  `http.trusted_proxies` ([docs/reverse-proxy.md](docs/reverse-proxy.md)).
- Backups contain `.storage`, i.e. tokens and integration credentials. Protect `HA_BACKUP_DIR`.
