#!/usr/bin/env bash
# scripts/install.sh: install or update Home Assistant as rootless Quadlet units (podman 4.9.3,
# systemd --user, linger). Idempotent: an unchanged re-run restarts nothing.
#
#   scripts/install.sh [options]
#
#   --with-matter | --without-matter              optional Matter server        (HA_MATTER)
#   --with-postgres | --without-postgres          optional PostgreSQL recorder  (HA_POSTGRES)
#   --with-backup-timer | --without-backup-timer  optional daily hot backup     (HA_BACKUP_TIMER)
#   --write-recorder-secret  with Postgres: add recorder_db_url to <config dir>/secrets.yaml
#                            when it is not there yet (configuration.yaml is never edited)
#   --no-start               install the files and daemon-reload only
#   --no-smoke               skip tests/smoke.sh at the end
#   --dry-run                render, validate and report what would change; touch nothing
#   --allow-image-change     used by upgrade.sh: install a different HA image than the installed
#                            one (on its own, install.sh refuses: version changes need upgrade.sh)
#
# Settings come from ~/.config/homeassistant/homeassistant.env (decision D2: rendered at install
# time). The first run creates it from config/homeassistant.env.example and stops for review.
# The --with/--without choices are saved there, so a plain re-run keeps them; a deselected
# unit is stopped and removed, and its data is kept.
#
# It refuses to run while a container named "homeassistant" exists that Quadlet does not
# manage, or while a hand-written unit that runs one is active or enabled: Quadlet starts HA
# with `podman run --replace`, which would delete that container. scripts/migrate-legacy.sh
# adopts such a deployment with a backup and a rollback.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=ha-common.sh
. "$REPO/scripts/ha-common.sh"
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"
PODMAN_MIN=4.9

sel_matter='' sel_pg='' sel_timer='' write_secret=0 no_start=0 no_smoke=0 allow_image_change=0
while (($#)); do
  case $1 in
    --with-matter) sel_matter=true ;;
    --without-matter) sel_matter=false ;;
    --with-postgres) sel_pg=true ;;
    --without-postgres) sel_pg=false ;;
    --with-backup-timer) sel_timer=true ;;
    --without-backup-timer) sel_timer=false ;;
    --write-recorder-secret) write_secret=1 ;;
    --no-start) no_start=1 ;;
    --no-smoke) no_smoke=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    --allow-image-change) allow_image_change=1 ;;
    -h | --help) sed -n '2,27p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ----------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
ql_lock "$HA_APP"
# ---- 2. per-host settings --------------------------------------------------------------------
ql_env_ensure "$REPO/config/$HA_APP.env.example" "$HA_ENV_FILE"
envf=$HA_ENV_FILE
if [[ $QL_ENV_CREATED == 1 ]]; then
  ql_env_load "$envf"
  [[ -z $sel_matter ]] || ql_env_set "$envf" HA_MATTER "$sel_matter"
  [[ -z $sel_pg ]] || ql_env_set "$envf" HA_POSTGRES "$sel_pg"
  [[ -z $sel_timer ]] || ql_env_set "$envf" HA_BACKUP_TIMER "$sel_timer"
  ql_info "review $envf (HA_CONFIG_DIR, devices, time zone), then run $0 again"
  exit 0
fi
if [[ ! -f $envf ]]; then
  # --dry-run on a host without the settings file: show what the example would give
  envf=$REPO/config/$HA_APP.env.example
  QL_ENV_MODE_CHECK=0 ql_env_load "$envf"
  ql_warn "[dry-run] $HA_ENV_FILE does not exist yet; using $envf"
else
  ql_env_load "$envf"
fi
for kv in "HA_MATTER=$sel_matter" "HA_POSTGRES=$sel_pg" "HA_BACKUP_TIMER=$sel_timer"; do
  k=${kv%%=*} v=${kv#*=}
  [[ -n $v && $(ql_env_get "$k" false) != "$v" ]] || continue
  [[ $envf == "$HA_ENV_FILE" ]] && ql_env_set "$envf" "$k" "$v"
  QL_ENV[$k]=$v
  ((dry)) || ql_info "saved $k=$v in $envf"
done
for k in HA_MATTER HA_POSTGRES HA_BACKUP_TIMER; do
  ql_assert_match "$k" "$(ql_env_get "$k" false)" 'true|false'
done
with_matter=0 with_pg=0 with_timer=0
if ha_on HA_MATTER; then with_matter=1; fi
if ha_on HA_POSTGRES; then with_pg=1; fi
if ha_on HA_BACKUP_TIMER; then with_timer=1; fi
port=$(ql_env_get HA_PORT 8123)
dbport=$(ql_env_get HA_DB_PORT 15432)
inst_img=$(ha_installed_image)
repo_img=$(ha_repo_image)
if [[ -n $inst_img && $inst_img != "$repo_img" ]] && ((!allow_image_change)); then
  ql_die "this checkout pins $repo_img but $inst_img is installed. Change versions with scripts/upgrade.sh (backup, smoke check, automatic rollback)"
fi

# ---- 3. host checks ----------------------------------------------------------------------------
ha_check_config_dir 1
cfg=$(ha_config_dir)
ha_check_devices
if ha_on HA_BLUETOOTH && [[ ! -d /run/dbus ]]; then
  ql_die "HA_BLUETOOTH=true but /run/dbus does not exist (install dbus and bluez)"
fi
tz=$(ql_env_get HA_TZ '')
if [[ -n $tz && $tz != local && ! -e /usr/share/zoneinfo/$tz ]]; then
  ql_warn "HA_TZ=$tz is not in /usr/share/zoneinfo; check the name"
fi

# ---- 4. legacy guards --------------------------------------------------------------------------
mapfile -t legacy_units < <(ha_legacy_units "$HA_CONTAINER")
for u in "${legacy_units[@]}"; do
  if systemctl --user is-active --quiet "$u" 2>/dev/null; then
    ql_die "legacy unit $u is running Home Assistant. Adopt it with scripts/migrate-legacy.sh (backup, rename, install, compare, rollback)"
  fi
  if [[ $(systemctl --user is-enabled "$u" 2>/dev/null || true) == enabled ]]; then
    ql_die "legacy unit $u is enabled: at boot it would stop and restart a container named $HA_CONTAINER. Use scripts/migrate-legacy.sh, or: systemctl --user disable $u"
  fi
done
if ha_container_exists "$HA_CONTAINER" && [[ $(ha_container_unit "$HA_CONTAINER") != "$HA_UNIT" ]]; then
  ql_warn "to adopt an existing Home Assistant container with a backup and a rollback, run scripts/migrate-legacy.sh"
fi
ql_check_container_collision "$HA_CONTAINER" "$HA_UNIT"
((with_matter == 0)) || ql_check_container_collision "$HA_MATTER_CONTAINER" "$HA_MATTER_UNIT"
((with_pg == 0)) || ql_check_container_collision "$HA_DB_CONTAINER" "$HA_DB_UNIT"
ql_check_path_mounted "$cfg" "$HA_CONTAINER"
# Ports are only checked when the container is not running: when it is, the collision guard
# above has already confirmed that it is ours, and it is the one holding them.
if ! ha_container_running "$HA_CONTAINER"; then
  ha_check_port die tcp "$port" "Home Assistant" "$HA_UNIT"
  ha_check_port warn tcp 21064 "HomeKit bridge" "$HA_UNIT"
  ha_check_port warn tcp 9584 "HA-MCP" "$HA_UNIT"
fi
if ((with_matter)) && ! ha_container_running "$HA_MATTER_CONTAINER"; then
  ha_check_port die tcp 5580 "Matter server" "$HA_MATTER_UNIT"
fi
if ((with_pg)) && ! ha_container_running "$HA_DB_CONTAINER"; then
  ha_check_port die tcp "$dbport" "PostgreSQL" "$HA_DB_UNIT"
fi

# ---- 5. stage the selected units, render, validate --------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$HA_APP-install.XXXXXX")
ql_cleanup work rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/out"
opt=$REPO/quadlet/optional
cp -p "$REPO/quadlet/homeassistant.container" "$WORK/src/"
units=()
if ((with_pg)); then
  cp -p "$opt/homeassistant-db.container" "$opt/homeassistant-db-data.volume" "$opt/homeassistant.network" "$WORK/src/"
  units+=("$HA_DB_UNIT")
fi
if ((with_matter)); then
  cp -p "$opt/homeassistant-matter.container" "$opt/homeassistant-matter-data.volume" "$WORK/src/"
  units+=("$HA_MATTER_UNIT")
fi
units+=("$HA_UNIT")
if ((with_timer)); then
  cp -p "$REPO/systemd/homeassistant-backup.service" "$REPO/systemd/homeassistant-backup.timer" "$WORK/src/"
  units+=("$HA_TIMER_UNIT")
fi
RENDER_ARGS=()
render_args "$envf"
ql_render "$WORK/src" "$envf" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
ql_dryrun "$WORK/out" --verify --ref-dir "$HA_QUADLET_DIR" \
  || ql_die "the rendered units failed the dry-run; nothing was installed"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$HA_APP"
done

# optional units that were installed earlier and are now deselected
deselect=()
((with_pg)) || for f in homeassistant-db.container homeassistant-db-data.volume homeassistant.network; do
  if ha_installed "$f"; then deselect+=("$f"); fi
done
((with_matter)) || for f in homeassistant-matter.container homeassistant-matter-data.volume; do
  if ha_installed "$f"; then deselect+=("$f"); fi
done
((with_timer)) || for f in homeassistant-backup.timer homeassistant-backup.service; do
  if ha_installed "$f"; then deselect+=("$f"); fi
done

# ---- 6. images and secrets before any unit changes (a pull never runs inside a start timeout) --
ql_pull_images "$WORK/out"
((with_pg == 0)) || ql_secret_ensure "$HA_DB_SECRET" random:48

# ---- 7. install changed files, then start / restart only what changed --------------------------
if ((${#deselect[@]})); then
  ql_info "removing deselected units (their volumes and data are kept): ${deselect[*]}"
  ql_remove_files "$HA_APP" "${deselect[@]}"
fi
changed=$(ql_install_files "$WORK/out" "$HA_APP")
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
if ((dry)); then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start ${units[*]}"
  exit 0
fi
ql_apply_units "$HA_APP" "${units[@]}"

# ---- 8. optional PostgreSQL recorder: HA only uses it once configuration.yaml says so ---------
if ((with_pg)); then
  if ((write_secret)); then
    sec=$cfg/secrets.yaml
    if [[ -f $sec ]] && grep -qE '^recorder_db_url:' "$sec"; then
      ql_info "$sec already has recorder_db_url; left alone"
    else
      xt=0
      [[ $- == *x* ]] && xt=1 && set +x
      pw=$(podman secret inspect --showsecret --format '{{.SecretData}}' "$HA_DB_SECRET") \
        || ql_die "cannot read podman secret $HA_DB_SECRET"
      [[ ! -s $sec || -z $(tail -c1 -- "$sec") ]] || printf '\n' >>"$sec"
      (umask 077 && printf 'recorder_db_url: "postgresql://homeassistant:%s@127.0.0.1:%s/homeassistant"\n' "$pw" "$dbport" >>"$sec")
      pw=''
      chmod 600 -- "$sec"
      ((xt)) && set -x
      ql_info "added recorder_db_url to $sec"
    fi
  fi
  ql_info "PostgreSQL recorder: add this to $cfg/configuration.yaml (see docs/postgres.md),"
  ql_info "then run: systemctl --user restart $HA_UNIT"
  printf '    recorder:\n      db_url: !secret recorder_db_url\n' >&2
  ((write_secret)) || ql_info "and put recorder_db_url in secrets.yaml (or re-run with --write-recorder-secret)"
fi

# ---- 9. smoke ------------------------------------------------------------------------------------
((no_smoke)) && { ql_info "installed (--no-smoke: checks skipped)"; exit 0; }
rc=0
ha_run_smoke --wait 900 || rc=$?
case $rc in
  0) ql_info "Home Assistant is installed and healthy" ;;
  2) ql_warn "Home Assistant is installed, but degraded checks failed (see the report above)"; exit 2 ;;
  *) ql_die "smoke checks failed; see: journalctl --user -u $HA_UNIT -n 100" ;;
esac
