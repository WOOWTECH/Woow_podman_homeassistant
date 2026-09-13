#!/usr/bin/env bash
# scripts/uninstall.sh: remove the Home Assistant Quadlet units. Keeps all data by default.
#
#   scripts/uninstall.sh                     stop and remove the units; keep the config dir, the
#                                            Matter/Postgres volumes, the secret, the images, the
#                                            settings file and the backups
#   scripts/uninstall.sh --purge [--yes]     also delete the Matter/Postgres volumes, the network,
#                                            the database secret and the pinned images, after a
#                                            final export of the volumes
#   scripts/uninstall.sh --purge --delete-config=<exact path> [--yes]
#                                            also delete the config dir, after a final archive of
#                                            it; the path must be the configured HA_CONFIG_DIR
#   scripts/uninstall.sh --dry-run [--purge] report what would be removed
#
# --purge is the only way this repo deletes data. The final copies go to
# $HA_BACKUP_DIR/ha-pre-purge-<timestamp>/. The settings file
# ~/.config/homeassistant/homeassistant.env and the backup dir are never deleted.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=ha-common.sh
. "$REPO/scripts/ha-common.sh"

purge=0 yes=0 delete_config=''
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --delete-config=*) delete_config=${1#--delete-config=} ;;
    --yes) yes=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ -z $delete_config ]] || ((purge)) || ql_die "--delete-config needs --purge"
dry=${QL_DRY_RUN:-0}

ql_require_rootless
ql_lock "$HA_APP"
if [[ -f $HA_ENV_FILE ]]; then ql_env_load "$HA_ENV_FILE"; fi

if ((!purge)); then
  ql_uninstall_units "$HA_APP"
  [[ ! -f $HA_ENV_FILE ]] || ql_info "kept the config dir $(ha_config_dir) and $HA_ENV_FILE"
  exit 0
fi

[[ -f $HA_ENV_FILE ]] || ql_die "--purge needs $HA_ENV_FILE (to find the config and backup dirs)"
cfg=$(ha_config_dir)
root=$(ha_backup_root)
if [[ -n $delete_config ]]; then
  want=$(realpath -m -- "$cfg")
  got=$(realpath -m -- "$delete_config")
  [[ $got == "$want" ]] || ql_die "--delete-config=$delete_config is not the configured HA_CONFIG_DIR ($want)"
  [[ $got != / && $got != "$(realpath -m -- "$HOME")" ]] || ql_die "refusing to delete $got"
  [[ -d $got ]] || ql_die "$got does not exist"
  [[ -e $got/.HA_VERSION || -e $got/configuration.yaml || -d $got/.storage ]] \
    || ql_die "$got does not look like a Home Assistant config dir (no .HA_VERSION, configuration.yaml or .storage)"
fi

if ((!dry)) && ((!yes)); then
  [[ -t 0 ]] || ql_die "--purge deletes data; add --yes to confirm non-interactively"
  what="volumes, network, secret and images"
  [[ -z $delete_config ]] || what+=", and the config dir $cfg"
  read -r -p "This deletes Home Assistant's $what. Type '$HA_APP' to go ahead: " answer
  [[ $answer == "$HA_APP" ]] || ql_die "aborted; nothing was deleted"
fi

imgs=()
for f in "$REPO/quadlet/homeassistant.container" "$REPO"/quadlet/optional/*.container; do
  imgs+=("$(ha_unit_image "$f")")
done
if ((dry)); then
  [[ -z $delete_config ]] || ql_info "[dry-run] would archive and delete $cfg"
  ql_info "[dry-run] would remove images: ${imgs[*]}"
  ql_uninstall_units "$HA_APP" --purge
  exit 0
fi

# final copies before anything is deleted; the units are stopped first so they are consistent
mapfile -t units < <(ha_units_installed)
((${#units[@]} == 0)) || systemctl --user stop "${units[@]}" || ql_warn "could not stop ${units[*]}"
ha_container_running "$HA_CONTAINER" && ql_die "container $HA_CONTAINER still runs outside $HA_UNIT; stop it first"
B=$root/ha-pre-purge-$(ha_ts)
for v in "$HA_MATTER_VOLUME" "$HA_DB_VOLUME"; do
  if podman volume exists "$v" >/dev/null 2>&1; then ql_backup_volume "$v" "$B" >/dev/null; fi
done
[[ -z $delete_config ]] || ql_backup_dir "$cfg" "$B/config.tgz" >/dev/null
[[ ! -d $B ]] || ql_info "final copies are in $B"

ql_uninstall_units "$HA_APP" --purge
for img in "${imgs[@]}"; do
  podman image exists "$img" || continue
  if podman rmi "$img" >/dev/null 2>&1; then ql_info "removed image $img"; else ql_warn "kept image $img (used by a container?)"; fi
done
if [[ -n $delete_config ]]; then
  podman unshare rm -rf -- "$cfg" || ql_die "could not delete $cfg"
  ql_info "deleted $cfg (archive: $B/config.tgz)"
fi
ql_info "purged. Kept: $HA_ENV_FILE and $root"
