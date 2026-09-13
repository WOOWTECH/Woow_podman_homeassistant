#!/usr/bin/env bash
# scripts/upgrade.sh: move Home Assistant to the version pinned in this checkout, with a cold
# backup and an automatic rollback.
#
#   git pull (or check out a release tag), then:
#   scripts/upgrade.sh [--yes] [--strict] [--force] [--prune-images]
#   scripts/upgrade.sh --rollback [<backup-dir>] [--yes]
#
# 1. HA must be healthy (manifest.json 200), unless --force
# 2. snapshot for the later comparison (tests/smoke.sh --snapshot)
# 3. render and dry-run the new units; pull the new images while HA still runs
# 4. stop HA (graceful, up to 300 s) and take a cold backup: config dir, Matter volume,
#    Postgres dump, the installed unit files ($HA_BACKUP_DIR/ha-pre-upgrade-<ver>-<ts>/backup)
# 5. install the new units and start HA (scripts/install.sh --allow-image-change)
# 6. tests/smoke.sh --compare against the snapshot, waiting up to 20 minutes for recorder
#    migrations
# A critical failure rolls back on its own: stop HA, restore the config dir from the cold
# backup (mandatory, because HA cannot run the old version on a migrated recorder schema or
# .storage), reinstall the saved unit files, start, smoke, exit 1. Degraded checks alone (for
# example HA-MCP when PyPI is unreachable) never roll back; they exit 2.
#
#   --strict        every config entry that was loaded before is critical (default: zha, homekit)
#   --force         go ahead although HA is not healthy now
#   --prune-images  after a successful upgrade, remove local HA images other than the new one
#                   and the one it replaced (images still used by a container are kept)
#   --rollback [D]  by hand: restore the newest pre-upgrade backup (or D) with its unit files
#   --yes           do not ask for confirmation
# The previous image stays on disk, so a rollback needs no download.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=ha-common.sh
. "$REPO/scripts/ha-common.sh"
PODMAN_MIN=4.9

yes=0 strict=0 force=0 prune=0 rollback=0 rb_dir=''
while (($#)); do
  case $1 in
    --yes) yes=1 ;;
    --strict) strict=1 ;;
    --force) force=1 ;;
    --prune-images) prune=1 ;;
    --rollback)
      rollback=1
      if [[ ${2:-} != '' && ${2:-} != -* ]]; then rb_dir=$2; shift; fi
      ;;
    -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done

ql_preflight "$PODMAN_MIN"
ql_lock "$HA_APP"
ha_env_require
root=$(ha_backup_root)
port=$(ql_env_get HA_PORT 8123)

# restore <backup-dir>: the rollback (restore.sh handles stop, config swap, units, start, smoke)
restore() {
  local rc=0
  "$REPO/scripts/restore.sh" "$1" --with-unit --yes --aside-tag "${2:-pre-restore}" || rc=$?
  return "$rc"
}

if ((rollback)); then
  if [[ -z $rb_dir ]]; then
    rb_dir=$(find "$root" -mindepth 2 -maxdepth 2 -type d -path '*/ha-pre-upgrade-*/backup' 2>/dev/null | LC_ALL=C sort | tail -n1)
    [[ -n $rb_dir ]] || ql_die "no pre-upgrade backup under $root"
  fi
  ql_info "rolling back to $rb_dir (HA $(ha_kv_get "$rb_dir/manifest.env" HA_VERSION || echo '?'))"
  ha_confirm "Restore that backup and its unit files? Changes made since that upgrade are lost." "$yes"
  rc=0
  restore "$rb_dir" || rc=$?
  ql_warn "this checkout still pins $(ha_repo_image); check out the previous version before running install.sh or upgrade.sh"
  exit "$rc"
fi

old_img=$(ha_installed_image)
new_img=$(ha_repo_image)
[[ -n $old_img ]] || ql_die "Home Assistant is not installed by this repo; run scripts/install.sh (or scripts/migrate-legacy.sh)"
if [[ $old_img == "$new_img" ]]; then
  ql_info "already on $new_img; applying any other unit changes with install.sh"
  exec "$REPO/scripts/install.sh"
fi
old_ver=$(ha_image_version "$old_img")
new_ver=$(ha_image_version "$new_img")
if [[ -n $old_ver && -n $new_ver && $(ha_version_cmp "$new_ver" "$old_ver") == -1 ]]; then
  ql_die "$new_img is older than the installed $old_img: downgrades need the matching backup (scripts/upgrade.sh --rollback, or scripts/restore.sh <dir> --with-unit)"
fi
ql_info "upgrade: $old_img -> $new_img"

# ---- 1-2. health and snapshot ----------------------------------------------------------------
if ! ql_wait_http "http://127.0.0.1:$port/manifest.json" 200 60; then
  ((force)) || ql_die "Home Assistant is not healthy now; fix that first, or add --force"
  ql_warn "--force: upgrading an unhealthy Home Assistant"
fi
ts=$(ha_ts)
B=$root/ha-pre-upgrade-${old_ver:-unknown}-$ts
(umask 077 && mkdir -p -- "$B") || ql_die "cannot create $B"
rc=0
ha_run_smoke --snapshot "$B/pre-upgrade.json" || rc=$?
if ((rc == 1)) && ((!force)); then
  ql_die "the pre-upgrade checks fail (see above); fix that first, or add --force"
fi

# ---- 3. validate the new units, pull while HA runs ---------------------------------------------
"$REPO/scripts/install.sh" --dry-run --allow-image-change --no-smoke \
  || ql_die "the new units do not validate; nothing was changed"
imgs=("$new_img")
ha_on HA_MATTER && imgs+=("$(ha_unit_image "$REPO/quadlet/optional/homeassistant-matter.container")")
ha_on HA_POSTGRES && imgs+=("$(ha_unit_image "$REPO/quadlet/optional/homeassistant-db.container")")
for img in "${imgs[@]}"; do
  podman image exists "$img" && continue
  ql_info "pulling $img (Home Assistant keeps running)"
  podman pull "$img" >/dev/null || ql_die "podman pull $img failed; nothing was changed"
done
ha_confirm "Upgrade Home Assistant ${old_ver:-?} -> ${new_ver:-?}? It is down for a few minutes." "$yes"

# ---- 4. stop and cold backup -----------------------------------------------------------------
ql_info "stopping $HA_UNIT (graceful, up to 300 s)"
systemctl --user stop "$HA_UNIT" || ql_die "could not stop $HA_UNIT"
if ! "$REPO/scripts/backup.sh" --cold --dest "$B/backup" --no-prune >/dev/null; then
  ql_warn "the cold backup failed; starting the unchanged Home Assistant again"
  systemctl --user start "$HA_UNIT" || true
  ql_die "upgrade aborted before any change (backup failed)"
fi

# ---- 5-6. install, smoke, roll back on a critical failure -------------------------------------
rollback_now() {
  ql_warn "ROLLING BACK to ${old_ver:-the previous version}: $1"
  local rrc=0
  restore "$B/backup" failed || rrc=$?
  if ((rrc == 0 || rrc == 2)); then
    ql_warn "rolled back to $old_img (smoke exit $rrc). The failed upgrade's config dir is kept as $(ha_config_dir).failed-*"
  else
    ql_warn "the rollback itself did not pass its checks (exit $rrc); see the report above and $B"
  fi
  ql_warn "this checkout still pins $new_img; check out the previous version before running install.sh"
  exit 1
}
if ! "$REPO/scripts/install.sh" --allow-image-change --no-smoke; then
  rollback_now "install.sh failed"
fi
rc=0
sargs=(--wait 1200 --compare "$B/pre-upgrade.json")
((strict)) && sargs+=(--strict)
ha_run_smoke "${sargs[@]}" || rc=$?
((rc == 1)) && rollback_now "critical post-upgrade checks failed"

ql_info "upgraded to $new_img; backup and snapshot in $B"
ql_info "manual rollback while this backup is current: scripts/upgrade.sh --rollback $B/backup"
if ((prune)); then
  repo_name=${new_img%:*}
  while IFS= read -r img; do
    [[ $img == "$new_img" || $img == "$old_img" || $img == *'<none>'* ]] && continue
    if podman rmi "$img" >/dev/null 2>&1; then ql_info "removed image $img"; else ql_warn "kept image $img (in use?)"; fi
  done < <(podman images --format '{{.Repository}}:{{.Tag}}' "$repo_name" 2>/dev/null)
fi
((rc == 2)) && { ql_warn "upgrade kept, but degraded checks failed (see above)"; exit 2; }
exit 0
