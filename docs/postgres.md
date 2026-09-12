# PostgreSQL recorder (optional)

The default recorder is SQLite in the config dir (`home-assistant_v2.db`). That is what upstream
ships and it is fine for most installations, including several hundred entities. Use PostgreSQL
when the SQLite file has grown past a few gigabytes, when purges and repacks take too long, or
when you want the recorder on a different filesystem.

Back to [README](../README.md).

## Read this before switching an existing install

**Home Assistant does not migrate SQLite history into PostgreSQL.** Pointing the recorder at a new
database starts it empty: history, statistics and long-term statistics begin from that moment. The
old `home-assistant_v2.db` is left in the config dir; keep it if you want to be able to go back.

Switching back later is the same one-way step in the other direction.

## Install and remove

```bash
scripts/install.sh --with-postgres                          # sets HA_POSTGRES=true
scripts/install.sh --with-postgres --write-recorder-secret  # and append recorder_db_url for you
scripts/install.sh --without-postgres                       # sets HA_POSTGRES=false
```

Selecting PostgreSQL installs three files:

- `homeassistant-db.container` - `docker.io/library/postgres:16.15-alpine`, container name
  `homeassistant-db`
- `homeassistant-db-data.volume` - `VolumeName=homeassistant-db-data`
- `homeassistant.network` - `NetworkName=homeassistant`, used only by the database

The database unit carries `RequiredBy=homeassistant.service` and `Before=homeassistant.service`, so
Home Assistant requires it and starts after it without any edit to `homeassistant.container`.

`--without-postgres` stops and removes those units but **keeps the volume and the data**. Only
`scripts/uninstall.sh --purge` deletes it, after a final export.

## Port

```ini
HA_DB_PORT=15432
```

Home Assistant runs on the host network, so it reaches the database over loopback. The container
publishes `127.0.0.1:$HA_DB_PORT:5432`. The default is 15432, not 5432, because a host that
already runs another PostgreSQL would collide. Nothing outside the host can reach it.

## Password

`scripts/install.sh` creates the podman secret `homeassistant-db-password` from 48 random
characters on the first `--with-postgres` run. The unit consumes it with
`Secret=homeassistant-db-password,type=env,target=POSTGRES_PASSWORD`.

The password is never printed, never written into a unit file and never stored in this repo. Read
it back only when you need it:

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' homeassistant-db-password
```

## Point Home Assistant at it

`install.sh` never edits `configuration.yaml`. Add this yourself:

```yaml
recorder:
  db_url: !secret recorder_db_url
```

and put the URL in `<HA_CONFIG_DIR>/secrets.yaml` (mode 0600):

```yaml
recorder_db_url: "postgresql://homeassistant:<password>@127.0.0.1:15432/homeassistant"
```

`scripts/install.sh --with-postgres --write-recorder-secret` appends exactly that line for you,
with the real password and port, but only when `secrets.yaml` does not already have a
`recorder_db_url` key. It still leaves `configuration.yaml` to you.

Then restart Home Assistant:

```bash
systemctl --user restart homeassistant.service
journalctl --user -u homeassistant.service -f     # watch the recorder connect
```

## Checks

```bash
systemctl --user status homeassistant-db.service
podman healthcheck run homeassistant-db                    # pg_isready
podman exec homeassistant-db psql -U homeassistant -d homeassistant -c '\dt'
podman exec homeassistant-db psql -U homeassistant -d homeassistant \
  -c "select pg_size_pretty(pg_database_size('homeassistant'))"
```

## Backup and restore

When the database is installed, `scripts/backup.sh` adds a logical dump
(`homeassistant-db.sql.gz`, `pg_dump --no-owner`) next to `config.tgz`, in hot and cold backups
alike: a cold backup stops Home Assistant and the Matter server, not the database. If the
database container happens to be stopped, the volume is exported instead of dumped.

`scripts/restore.sh <backup-dir>` restores it: it dumps the current database aside first, then
drops and recreates `homeassistant` and loads the dump. If a backup carries a dump but the
database unit is not installed, the restore says so and skips it.

## See also

- [docs/hardware.md](hardware.md) - radios, Bluetooth, time zone
- [docs/matter.md](matter.md) - the optional Matter server
- [docs/reverse-proxy.md](reverse-proxy.md) - Cloudflare tunnel and Nginx Proxy Manager
