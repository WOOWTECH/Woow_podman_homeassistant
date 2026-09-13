#!/usr/bin/env bash
# scripts/backup.sh: back up the Home Assistant config dir and the optional Matter/Postgres data.
#
#   scripts/backup.sh [--hot | --cold [--stop]] [--dest DIR] [--no-prune]
#
#   --hot       HA keeps running. The SQLite databases at the top of the config dir
#               (home-assistant_v2.db, zigbee.db, ...) are copied with SQLite's online backup
#               API inside the container and checked with PRAGMA quick_check; the rest of the
#               config dir is archived without them, the logs and tts/.
#   --cold      HA must be stopped: a consistent copy of everything. --stop stops HA (and the
#               Matter server) for the backup and starts them again afterwards.
#   (neither)   --hot when HA is running, otherwise --cold.
#   --dest DIR  write into DIR (new or empty) instead of $HA_BACKUP_DIR/ha-<hot|cold>-<timestamp>
#   --no-prune  keep every backup (default: keep the newest HA_BACKUP_KEEP ha-<hot|cold>-* dirs;
#               backups written by upgrade.sh, migrate-legacy.sh and --dest are never pruned)
#
# A backup is a 0700 directory holding config.tgz (podman unshare tar, numeric owners),
# sqlite/*.db.gz (hot only), homeassistant-matter-data-*.tar and homeassistant-db.sql.gz when
# those are installed, units/ (the installed unit files), homeassistant.env, manifest.env and
# SHA256SUMS. scripts/restore.sh reads it. The backup directory is printed on stdout.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=ha-common.sh
. "$REPO/scripts/ha-common.sh"

mode='' stop=0 dest='' prune=1
while (($#)); do
  case $1 in
    --hot) mode=hot ;;
    --cold) mode=cold ;;
    --stop) stop=1 ;;
    --dest) dest=${2:?--dest needs a directory}; shift ;;
    --no-prune) prune=0 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done

ql_require_rootless
ha_lock
ha_env_require
cfg=$(ha_config_dir)
[[ -d $cfg ]] || ql_die "HA_CONFIG_DIR $cfg does not exist"
root=$(ha_backup_root)
keep=$(ql_env_get HA_BACKUP_KEEP 5)
ql_assert_match HA_BACKUP_KEEP "$keep" '[1-9][0-9]*'

running=0
ha_container_running "$HA_CONTAINER" && running=1
if [[ -z $mode ]]; then
  mode=cold
  ((running)) && mode=hot
fi
[[ $mode == hot && $running == 0 ]] && ql_die "Home Assistant is not running; use --cold"

ts=$(ha_ts)
auto=0
if [[ -z $dest ]]; then
  dest=$root/ha-$mode-$ts
  auto=1
elif [[ -e $dest ]]; then
  [[ -d $dest && -z $(ls -A -- "$dest") ]] || ql_die "$dest exists and is not empty"
fi

stopped=() tmp_in_cfg='' done_ok=0
finish() {
  local rc=$?
  [[ -z $tmp_in_cfg ]] || rm -rf -- "$tmp_in_cfg"
  if ((${#stopped[@]})); then
    ql_info "starting again: ${stopped[*]}"
    systemctl --user start "${stopped[@]}" || ql_warn "could not start ${stopped[*]}; start them by hand"
  fi
  if ((!done_ok && auto)) && [[ -d $dest ]]; then
    ql_warn "backup failed; removing the incomplete $dest"
    rm -rf -- "$dest"
  fi
  return "$rc"
}
trap finish EXIT

if [[ $mode == cold ]] && ((running)); then
  ((stop)) || ql_die "Home Assistant is running; stop it first (systemctl --user stop $HA_UNIT) or add --stop"
  for u in "$HA_MATTER_UNIT" "$HA_UNIT"; do
    systemctl --user is-active --quiet "$u" 2>/dev/null || continue
    ql_info "stopping $u for a cold backup"
    stopped+=("$u")
    systemctl --user stop "$u" || ql_die "could not stop $u"
  done
  ha_container_running "$HA_CONTAINER" && ql_die "$HA_CONTAINER is still running (not started by $HA_UNIT?); stop it first"
fi

# space: the compressed backup is smaller than the config dir; ask for its size plus 100 MiB
need=$( (du -sk -- "$cfg" 2>/dev/null || true) | cut -f1)
free=$(ha_free_kb "$dest")
if [[ $need =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] && ((free < need + 102400)); then
  ql_die "not enough space for $dest: about $((need / 1024)) MiB needed, $((free / 1024)) MiB free"
fi
(umask 077 && mkdir -p -- "$dest") || ql_die "cannot create $dest"
chmod 700 -- "$dest"
base=$(basename -- "$cfg")
ql_info "$mode backup of $cfg -> $dest"

if [[ $mode == hot ]]; then
  # SQLite online backup inside the container (the same SQLite that HA uses), then quick_check
  read -r -d '' SQLITE_COPY <<'PY' || true
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
s = sqlite3.connect(src, timeout=120)
d = sqlite3.connect(dst)
try:
    s.backup(d)
finally:
    d.close()
    s.close()
c = sqlite3.connect(dst)
r = c.execute("PRAGMA quick_check").fetchone()[0]
c.close()
sys.exit(0 if r == "ok" else "quick_check: %s" % r)
PY
  mapfile -t dbs < <(find "$cfg" -maxdepth 1 -type f -name '*.db' -printf '%f\n' | LC_ALL=C sort)
  tmpname=.woow-backup-$ts
  excludes=(--exclude "$base/$tmpname" --exclude "$base/home-assistant.log*" --exclude "$base/tts")
  if ((${#dbs[@]})); then
    tmp_in_cfg=$cfg/$tmpname
    mkdir -p -- "$tmp_in_cfg" "$dest/sqlite"
    for db in "${dbs[@]}"; do
      ql_info "online backup of $db"
      podman exec "$HA_CONTAINER" python3 -c "$SQLITE_COPY" "/config/$db" "/config/$tmpname/$db" \
        || ql_die "SQLite online backup of $db failed"
      (umask 077 && gzip -c -- "$tmp_in_cfg/$db" >"$dest/sqlite/$db.gz.partial") || ql_die "cannot compress $db"
      mv -f -- "$dest/sqlite/$db.gz.partial" "$dest/sqlite/$db.gz"
      rm -f -- "$tmp_in_cfg/$db"
      for s in '' -wal -shm -journal; do excludes+=(--exclude "$base/$db$s"); done
    done
    rm -rf -- "$tmp_in_cfg"
    tmp_in_cfg=''
  fi
  ql_backup_dir "$cfg" "$dest/config.tgz" "${excludes[@]}" >/dev/null
else
  ql_backup_dir "$cfg" "$dest/config.tgz" >/dev/null
fi

# optional components
if podman volume exists "$HA_MATTER_VOLUME" >/dev/null 2>&1; then
  if [[ $mode == cold ]] && systemctl --user is-active --quiet "$HA_MATTER_UNIT" 2>/dev/null; then
    ql_info "stopping $HA_MATTER_UNIT to export its volume"
    stopped+=("$HA_MATTER_UNIT")
    systemctl --user stop "$HA_MATTER_UNIT" || ql_die "could not stop $HA_MATTER_UNIT"
  fi
  ql_backup_volume "$HA_MATTER_VOLUME" "$dest" >/dev/null
fi
if ha_container_running "$HA_DB_CONTAINER"; then
  ql_info "pg_dump of the recorder database"
  if ! (umask 077 && podman exec "$HA_DB_CONTAINER" pg_dump -U homeassistant -d homeassistant --no-owner | gzip >"$dest/homeassistant-db.sql.gz.partial"); then
    ql_die "pg_dump through $HA_DB_CONTAINER failed"
  fi
  mv -f -- "$dest/homeassistant-db.sql.gz.partial" "$dest/homeassistant-db.sql.gz"
elif podman volume exists "$HA_DB_VOLUME" >/dev/null 2>&1; then
  ql_backup_volume "$HA_DB_VOLUME" "$dest" >/dev/null
fi

# what is needed to put the same version back: unit files, settings, manifest
mkdir -p -- "$dest/units"
while IFS= read -r p; do
  [[ -f $p ]] && cp -p -- "$p" "$dest/units/"
done < <(ha_manifest_files)
[[ ! -f $HA_ENV_FILE ]] || install -m 600 -- "$HA_ENV_FILE" "$dest/homeassistant.env"
img=$(ha_installed_image)
[[ -n $img ]] || img=$(podman container inspect --format '{{.ImageName}}' "$HA_CONTAINER" 2>/dev/null || true)
{
  printf 'BACKUP_FORMAT=1\n'
  printf 'CREATED=%s\n' "$(date -Iseconds)"
  printf 'MODE=%s\n' "$mode"
  printf 'HA_VERSION=%s\n' "$(cat -- "$cfg/.HA_VERSION" 2>/dev/null || true)"
  printf 'IMAGE=%s\n' "$img"
  printf 'CONFIG_DIR=%s\n' "$(ql_env_get HA_CONFIG_DIR)"
  printf 'CONFIG_BASENAME=%s\n' "$base"
  printf 'REPO_COMMIT=%s\n' "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} >"$dest/manifest.env"
chmod 600 -- "$dest/manifest.env"
# the sums are written outside $dest: a file created there first would list itself
sums=$(mktemp "${TMPDIR:-/tmp}/ha-sha256sums.XXXXXX") || ql_die "cannot create a temporary file"
(cd -- "$dest" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort \
  | xargs -r -d '\n' sha256sum --) >"$sums" || { rm -f -- "$sums"; ql_die "cannot write $dest/SHA256SUMS"; }
mv -f -- "$sums" "$dest/SHA256SUMS" || ql_die "cannot write $dest/SHA256SUMS"
chmod 600 -- "$dest/SHA256SUMS"
done_ok=1

if ((auto && prune)); then
  mapfile -t old < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name "ha-$mode-*" -printf '%f\n' | LC_ALL=C sort)
  n=${#old[@]}
  if ((n > keep)); then
    for d in "${old[@]:0:n-keep}"; do
      rm -rf -- "${root:?}/$d"
      ql_info "pruned $root/$d (HA_BACKUP_KEEP=$keep)"
    done
  fi
fi
ql_info "backup complete: $dest ($(du -sh -- "$dest" | cut -f1))"
printf '%s\n' "$dest"
