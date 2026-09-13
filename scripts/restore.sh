#!/usr/bin/env bash
# scripts/restore.sh: restore a backup written by scripts/backup.sh (upgrade.sh and
# migrate-legacy.sh write the same format).
#
#   scripts/restore.sh <backup-dir> [--with-unit] [--forward] [--config-only] [--no-start] [--yes]
#
#   (default)      verify SHA256SUMS, stop HA, unpack the config dir next to the current one,
#                  move the current one aside to <config dir>.pre-restore-<timestamp>, put the
#                  backup in its place, restore the Matter volume and the Postgres dump when the
#                  backup has them, start HA and run tests/smoke.sh
#   --with-unit    also reinstall the unit files saved in the backup, i.e. its HA version. Needed
#                  when the backup comes from another HA version than the installed one: HA cannot
#                  run an older version on a newer config (schema and .storage migrations)
#   --forward      restore an older backup under the newer installed version; HA migrates the
#                  restored config forward on start, which cannot be undone
#   --config-only  the config dir only: no unit files, volumes or database, and no start
#                  (migrate-legacy.sh --rollback --restore-config uses it)
#   --no-start     leave everything stopped
#   --aside-tag T  name the moved-aside dir <config dir>.<T>-<timestamp> (upgrade.sh: failed)
#   --yes          do not ask for confirmation
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=ha-common.sh
. "$REPO/scripts/ha-common.sh"

bdir='' with_unit=0 forward=0 config_only=0 no_start=0 yes=0 tag=pre-restore
while (($#)); do
  case $1 in
    --with-unit) with_unit=1 ;;
    --forward) forward=1 ;;
    --config-only) config_only=1 ;;
    --no-start) no_start=1 ;;
    --aside-tag) tag=${2:?--aside-tag needs a name}; shift ;;
    --yes) yes=1 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $bdir ]] || ql_die "one backup directory only"; bdir=$1 ;;
  esac
  shift
done
[[ -n $bdir ]] || ql_die "usage: scripts/restore.sh <backup-dir> [options] (see --help)"
[[ $tag =~ ^[A-Za-z0-9_-]+$ ]] || ql_die "--aside-tag: letters, digits, - and _ only"
bdir=$(realpath -e -- "$bdir") || ql_die "backup directory not found"
[[ -f $bdir/manifest.env && -f $bdir/config.tgz && -f $bdir/SHA256SUMS ]] \
  || ql_die "$bdir is not a backup made by scripts/backup.sh (manifest.env, config.tgz, SHA256SUMS)"

ql_require_rootless
ql_lock "$HA_APP"
ha_env_require
cfg=$(ha_config_dir)
ts=$(ha_ts)

ql_info "verifying $bdir/SHA256SUMS"
(cd -- "$bdir" && sha256sum -c --quiet SHA256SUMS) || ql_die "checksum mismatch in $bdir; not restoring"
bver=$(ha_kv_get "$bdir/manifest.env" HA_VERSION || true)
bmode=$(ha_kv_get "$bdir/manifest.env" MODE || true)
ql_info "backup: ${bmode:-?} backup of HA ${bver:-unknown version}, $(ha_kv_get "$bdir/manifest.env" CREATED || echo '?')"

# ---- version rules ---------------------------------------------------------------------------
stage=''
if ((!config_only)); then
  if ((with_unit)); then
    [[ -f $bdir/units/homeassistant.container ]] || ql_die "the backup has no saved units/homeassistant.container; --with-unit is not possible"
    target=$(ha_image_version "$(ha_unit_image "$bdir/units/homeassistant.container")")
  else
    target=$(ha_image_version "$(ha_installed_image)")
    [[ -n $target ]] || target=$(ha_image_version "$(ha_repo_image)")
  fi
  if [[ -n $bver && -n $target ]]; then
    case $(ha_version_cmp "$bver" "$target") in
      1) ql_die "the backup is from HA $bver, newer than $target: HA cannot run an older version on it. Use --with-unit (restores $bver's units), or upgrade first" ;;
      -1) ((forward || with_unit)) || ql_die "the backup is from HA $bver, older than the installed $target. Use --with-unit to go back to $bver, or --forward to let $target migrate it (one-way)" ;;
    esac
  fi
fi
aside=$cfg.$tag-$ts
ha_confirm "Restore $bdir into $cfg? Home Assistant is stopped and the current config dir moves to $aside." "$yes"

# ---- images first, while HA still runs -------------------------------------------------------
if ((with_unit)); then
  stage=$(mktemp -d "${TMPDIR:-/tmp}/ha-restore-units.XXXXXX")
  ql_cleanup stage rm -rf "$stage"
  cp -p -- "$bdir"/units/* "$stage/"
  ql_pull_images "$stage"
fi

# ---- stop ------------------------------------------------------------------------------------
if ((config_only)); then
  ha_container_running "$HA_CONTAINER" && ql_die "container $HA_CONTAINER is running; stop Home Assistant first"
else
  for u in "$HA_UNIT" "$HA_MATTER_UNIT"; do
    systemctl --user is-active --quiet "$u" 2>/dev/null || continue
    ql_info "stopping $u"
    systemctl --user stop "$u" || ql_die "could not stop $u"
  done
  if ha_container_running "$HA_CONTAINER"; then
    ql_die "container $HA_CONTAINER still runs outside $HA_UNIT (a legacy container?); stop it first"
  fi
fi

# ---- config dir: unpack next to it, then swap -------------------------------------------------
parent=$(dirname -- "$cfg")
mkdir -p -- "$parent"
unpack=$(mktemp -d "$parent/.ha-restore.XXXXXX")
ql_info "unpacking config.tgz"
if ! podman unshare tar --numeric-owner -xzf "$bdir/config.tgz" -C "$unpack"; then
  podman unshare rm -rf -- "$unpack"
  ql_die "cannot unpack $bdir/config.tgz; $cfg was not touched"
fi
shopt -s nullglob dotglob
top=("$unpack"/*)
shopt -u nullglob dotglob
if ((${#top[@]} != 1)) || [[ ! -d ${top[0]} ]]; then
  podman unshare rm -rf -- "$unpack"
  ql_die "config.tgz should hold exactly one directory; $cfg was not touched"
fi
for gz in "$bdir"/sqlite/*.db.gz; do
  [[ -f $gz ]] || continue
  db=$(basename -- "$gz" .gz)
  ql_info "restoring $db from the online SQLite copy"
  gzip -dc -- "$gz" >"${top[0]}/$db" || { podman unshare rm -rf -- "$unpack"; ql_die "cannot unpack $gz"; }
done
if [[ -e $cfg ]]; then
  mv -- "$cfg" "$aside" || { podman unshare rm -rf -- "$unpack"; ql_die "cannot move $cfg aside"; }
  ql_info "moved the current config dir to $aside"
fi
mv -- "${top[0]}" "$cfg" || ql_die "cannot move the restored config into place; the old one is $aside"
rmdir -- "$unpack" 2>/dev/null || true
ql_info "config dir restored: $cfg"

if ((config_only)); then
  ql_info "done (--config-only). Undo with: rm -rf '$cfg' && mv '$aside' '$cfg'"
  exit 0
fi

# ---- optional components ---------------------------------------------------------------------
shopt -s nullglob
mtars=("$bdir"/"$HA_MATTER_VOLUME"-*.tar)
shopt -u nullglob
if ((${#mtars[@]})) && podman volume exists "$HA_MATTER_VOLUME" >/dev/null 2>&1; then
  ql_backup_volume "$HA_MATTER_VOLUME" "$aside.volumes" >/dev/null
  mp=$(podman volume inspect --format '{{.Mountpoint}}' "$HA_MATTER_VOLUME")
  podman unshare find "$mp" -mindepth 1 -delete || ql_die "cannot empty volume $HA_MATTER_VOLUME"
  podman volume import "$HA_MATTER_VOLUME" "${mtars[-1]}" || ql_die "cannot import ${mtars[-1]}"
  ql_info "restored volume $HA_MATTER_VOLUME (the previous content is in $aside.volumes/)"
elif ((${#mtars[@]})); then
  ql_warn "the backup has Matter data but $HA_MATTER_VOLUME is not installed; skipped (install.sh --with-matter, then restore again)"
fi
if [[ -f $bdir/homeassistant-db.sql.gz ]]; then
  if ha_installed homeassistant-db.container; then
    systemctl --user start "$HA_DB_UNIT" || ql_die "could not start $HA_DB_UNIT"
    ql_wait_container_healthy "$HA_DB_CONTAINER" 180 || ql_die "$HA_DB_CONTAINER is not healthy"
    (umask 077 && mkdir -p -- "$aside.volumes")
    podman exec "$HA_DB_CONTAINER" pg_dump -U homeassistant -d homeassistant --no-owner | gzip >"$aside.volumes/homeassistant-db.sql.gz" \
      || ql_die "cannot dump the current database first"
    podman exec "$HA_DB_CONTAINER" psql -v ON_ERROR_STOP=1 -q -U homeassistant -d postgres \
      -c 'DROP DATABASE IF EXISTS homeassistant WITH (FORCE)' -c 'CREATE DATABASE homeassistant OWNER homeassistant' \
      || ql_die "cannot recreate the database"
    gzip -dc -- "$bdir/homeassistant-db.sql.gz" | podman exec -i "$HA_DB_CONTAINER" psql -v ON_ERROR_STOP=1 -q -U homeassistant -d homeassistant >/dev/null \
      || ql_die "restoring the database dump failed (the previous database is in $aside.volumes/)"
    ql_info "restored the recorder database"
  else
    ql_warn "the backup has a Postgres dump but the database is not installed; skipped"
  fi
fi

# ---- units --------------------------------------------------------------------------------------
if ((with_unit)); then
  ql_install_files "$stage" "$HA_APP" >/dev/null
  ql_info "reinstalled the unit files from the backup ($(ha_installed_image))"
  ql_warn "this checkout pins $(ha_repo_image); check out the matching version before running install.sh again"
fi
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "restored; not started (--no-start)"
  exit 0
fi
mapfile -t units < <(ha_units_installed)
((${#units[@]})) || ql_die "no installed units to start; run scripts/install.sh"
ql_apply_units "$HA_APP" "${units[@]}"
rc=0
ha_run_smoke --wait 900 || rc=$?
case $rc in
  0) ql_info "restore complete; the previous config dir is $aside" ;;
  2) ql_warn "restored, but degraded checks failed; the previous config dir is $aside" ;;
  *) ql_warn "restored, but critical checks failed; the previous config dir is $aside" ;;
esac
exit "$rc"
