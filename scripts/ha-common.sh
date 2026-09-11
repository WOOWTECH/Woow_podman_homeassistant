# shellcheck shell=bash
# scripts/ha-common.sh: Home Assistant helpers shared by the scripts in this directory.
# Repo-owned. The generic Quadlet helpers live in lib/quadlet-lib.sh, which is vendored and
# never edited here. Source this after lib/quadlet-lib.sh, with REPO set to the checkout root.

# shellcheck disable=SC2034 # names are used by the scripts that source this file
HA_APP=homeassistant
HA_CONTAINER=homeassistant
HA_UNIT=homeassistant.service
HA_MATTER_CONTAINER=homeassistant-matter
HA_MATTER_UNIT=homeassistant-matter.service
HA_MATTER_VOLUME=homeassistant-matter-data
HA_DB_CONTAINER=homeassistant-db
HA_DB_UNIT=homeassistant-db.service
HA_DB_VOLUME=homeassistant-db-data
HA_DB_SECRET=homeassistant-db-password
HA_TIMER_UNIT=homeassistant-backup.timer
HA_ENV_FILE=${HA_ENV_FILE:-$HOME/.config/$HA_APP/$HA_APP.env}
HA_QUADLET_DIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
HA_SD_USER_DIR=${QL_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}
HA_STATE_DIR=${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}/$HA_APP
# tests/smoke.sh, overridable for the script tests
HA_SMOKE=${HA_SMOKE_CMD:-$REPO/tests/smoke.sh}
export QL_APP=$HA_APP

ha_ts() { date +%Y%m%d-%H%M%S; }

# ha_lock: take the per-app lock, or keep the one a calling script (upgrade.sh, restore.sh,
# migrate-legacy.sh) already holds. The caller exports HA_LOCK_FD and the fd is inherited;
# it is honoured only when it really is this app's lock file.
ha_lock() {
  local fd=${HA_LOCK_FD:-} want
  want=$(realpath -m -- "$HA_STATE_DIR/lock")
  if [[ $fd =~ ^[0-9]+$ && -e /proc/self/fd/$fd && $(readlink -f -- "/proc/self/fd/$fd") == "$want" ]]; then
    return 0
  fi
  ql_lock "$HA_APP"
  # shellcheck disable=SC2153 # QL_LOCK_FD is set by ql_lock in quadlet-lib.sh
  export HA_LOCK_FD=$QL_LOCK_FD
}

# ha_env_require: load the settings file that scripts/install.sh created
ha_env_require() {
  [[ -f $HA_ENV_FILE ]] || ql_die "$HA_ENV_FILE not found; run scripts/install.sh first"
  ql_env_load "$HA_ENV_FILE"
}

# ha_config_dir / ha_backup_root: the configured paths with %h expanded
ha_config_dir() {
  local v
  v=$(ql_env_get HA_CONFIG_DIR) || ql_die "HA_CONFIG_DIR is not set in ${QL_ENV_FILE:-the env file}"
  ql_expand_home "$v"
}
ha_backup_root() { ql_expand_home "$(ql_env_get HA_BACKUP_DIR "%h/backups/$HA_APP")"; }

# ha_on <KEY>: the boolean setting is true (missing = false)
ha_on() { [[ $(ql_env_get "$1" false) == true ]]; }

# ha_unit_image <container file>: its Image= value (nothing when the file does not exist)
ha_unit_image() {
  if [[ -f $1 ]]; then sed -n 's/^[[:space:]]*Image=[[:space:]]*//p' "$1" | tail -n1; fi
  return 0
}
ha_repo_image() { ha_unit_image "$REPO/quadlet/homeassistant.container"; }
ha_installed_image() { ha_unit_image "$HA_QUADLET_DIR/homeassistant.container"; }

# ha_image_version <image>: the tag when it looks like a version (2026.9.1), else nothing
ha_image_version() {
  local tail=${1##*/} tag=''
  [[ $1 != *@* && $tail == *:* ]] && tag=${tail#*:}
  [[ $tag =~ ^[0-9]+\.[0-9]+ ]] && printf '%s' "$tag"
  return 0
}

# ha_version_cmp <a> <b>: prints -1, 0 or 1 (version sort, 2026.10.0 > 2026.9.1)
ha_version_cmp() {
  if [[ $1 == "$2" ]]; then echo 0; return 0; fi
  if [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n 1p) == "$1" ]]; then echo -1; else echo 1; fi
}

ha_container_exists() { podman container exists "$1" >/dev/null 2>&1; }
ha_container_running() { [[ $(podman container inspect --format '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
# ha_container_unit <name>: its PODMAN_SYSTEMD_UNIT label ("" for a hand-made container)
ha_container_unit() {
  local l
  l=$(podman container inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$1" 2>/dev/null) || l=''
  [[ $l == '<no value>' ]] && l=''
  printf '%s' "$l"
}

# ha_manifest_files: absolute paths of the installed unit files (not config/) from the manifest
ha_manifest_files() {
  local m="$HA_STATE_DIR/manifest"
  [[ -f $m ]] || return 0
  sed -E 's/^[0-9a-f]+  //' "$m" | while IFS= read -r p; do
    case $p in */.config/$HA_APP/*) ;; *) printf '%s\n' "$p" ;; esac
  done
}
# ha_installed <basename>: the file is installed by this app
ha_installed() {
  local all
  all=$(ha_manifest_files)
  grep -qE "/${1//./\\.}\$" <<<"$all"
}

# ha_units_installed: the units this app has installed, in start order
ha_units_installed() {
  local u
  for u in homeassistant-db.container homeassistant-matter.container homeassistant.container homeassistant-backup.timer; do
    ha_installed "$u" && ql_unit_for "$u"
  done
  return 0
}

# ha_legacy_units <container>: hand-written user units whose Exec lines start or stop that
# container by name (podman-ha.service on toypark1234). Backup copies (*.bak) never match.
ha_legacy_units() {
  local name=${1//./\\.} f
  [[ -d $HA_SD_USER_DIR ]] || return 0
  for f in "$HA_SD_USER_DIR"/*.service; do
    [[ -f $f ]] || continue
    grep -qE "^[[:space:]]*Exec[A-Za-z]*=.*(^|[[:space:]=])${name}([[:space:]]|\$)" "$f" && printf '%s\n' "${f##*/}"
  done
  return 0
}

# ha_check_devices: every configured device exists and, with HA_PRIVILEGED=true, resolves to
# its container path. Rootless podman 4.9.3 drops --device mappings when --privileged is set
# (plan finding F2), so HA sees the host node names and the by-id mapping never applies.
ha_check_devices() {
  local priv dev tgt spec host cont real
  local -a q_specs=() q_extra=()
  priv=$(ql_env_get HA_PRIVILEGED true)
  dev=$(ql_env_get HA_ZIGBEE_DEVICE '')
  tgt=$(ql_env_get HA_ZIGBEE_TARGET /dev/ttyACM0)
  [[ -z $dev ]] || q_specs+=("$dev:$tgt")
  read -ra q_extra <<<"$(ql_env_get HA_EXTRA_DEVICES '')"
  q_specs+=("${q_extra[@]}")
  for spec in "${q_specs[@]}"; do
    host=${spec%%:*}
    cont=$host
    [[ $spec == *:* ]] && { cont=${spec#*:}; cont=${cont%%:*}; }
    [[ -e $host ]] || ql_die "device $host does not exist (plugged in? see: ls -l /dev/serial/by-id/)"
    real=$(readlink -f -- "$host")
    [[ -c $real ]] || ql_die "$host resolves to $real, which is not a character device"
    if [[ $priv == true ]]; then
      [[ $real == "$cont" ]] || ql_die "HA_PRIVILEGED=true: podman ignores the mapping $host -> $cont, so HA would see $real instead of $cont. Set the container path to $real (the ZHA/Z-Wave entry must use it too), or set HA_PRIVILEGED=false (docs/hardware.md)"
      ql_info "device $host -> $real (privileged: the host node is used as is)"
    else
      [[ -r $real && -w $real ]] || ql_warn "$real is not read/writable by $(id -un): add yourself to its group (keep-groups passes it on) or add a udev rule"
      ql_info "device $host -> $cont"
    fi
  done
  return 0
}

# ha_check_config_dir [create]: the config dir exists (created when asked) and is ours
ha_check_config_dir() {
  local cfg
  cfg=$(ha_config_dir)
  if [[ ! -e $cfg ]]; then
    [[ ${1:-0} == 1 ]] || ql_die "HA_CONFIG_DIR $cfg does not exist"
    if [[ ${QL_DRY_RUN:-0} == 1 ]]; then ql_info "[dry-run] would create $cfg"; return 0; fi
    mkdir -p -- "$cfg" || ql_die "cannot create $cfg"
    ql_info "created $cfg (Home Assistant starts with onboarding)"
  fi
  [[ -d $cfg ]] || ql_die "HA_CONFIG_DIR $cfg is not a directory"
  [[ -O $cfg ]] || ql_die "$cfg is not owned by $(id -un). HA runs as root in the rootless user namespace, which maps to your user, so the config dir must be yours"
  return 0
}

# ha_port_foreign <tcp|udp> <port> <unit...>: prints who listens on the port and returns 1
# when that is anything but processes of the given units (free, or ours: returns 0). With
# host networking HA (or Matter) cannot bind a port another process holds.
ha_port_foreign() {
  local proto=$1 port=$2 out pid cg u ok bad=''
  shift 2
  out=$(ss -Hlnp"${proto:0:1}" "sport = :$port" 2>/dev/null) || return 0
  [[ -n $out ]] || return 0
  local -a q_pids=()
  mapfile -t q_pids < <(grep -oE 'pid=[0-9]+' <<<"$out" | cut -d= -f2 | sort -u)
  if ((${#q_pids[@]} == 0)); then
    printf 'a process of another user'
    return 1
  fi
  for pid in "${q_pids[@]}"; do
    cg=$(cat "/proc/$pid/cgroup" 2>/dev/null) || cg=''
    ok=0
    for u in "$@"; do [[ $cg == *"/$u/"* || $cg == *"/$u" ]] && ok=1; done
    ((ok)) || bad+="${bad:+, }$(cat "/proc/$pid/comm" 2>/dev/null || echo '?') (pid $pid)"
  done
  [[ -z $bad ]] && return 0
  printf '%s' "$bad"
  return 1
}

# ha_check_port <die|warn> <tcp|udp> <port> <what> <unit...>
ha_check_port() {
  local how=$1 proto=$2 port=$3 what=$4 who
  shift 4
  who=$(ha_port_foreign "$proto" "$port" "$@") && return 0
  if [[ $how == die ]]; then
    ql_die "$proto port $port ($what) is in use by $who; stop it first"
  fi
  ql_warn "$proto port $port ($what) is in use by $who; that part of Home Assistant will not work until it is freed"
  return 0
}

# ha_device_holders <device>: pids of this user's processes that hold the device open
ha_device_holders() {
  local real fd pid
  real=$(readlink -f -- "$1")
  for fd in /proc/[0-9]*/fd/*; do
    [[ $(readlink -- "$fd" 2>/dev/null) == "$real" ]] || continue
    pid=${fd#/proc/}
    printf '%s\n' "${pid%%/*}"
  done | sort -u
  return 0
}

# ha_free_kb <dir>: free space (KiB) on the filesystem holding dir (or its nearest parent)
ha_free_kb() {
  local d=$1
  while [[ ! -d $d && $d == */* ]]; do d=${d%/*}; done
  df -Pk -- "${d:-/}" | awk 'NR == 2 { print $4 }'
}

# ha_run_smoke <args...>: tests/smoke.sh; returns its exit code (0 pass, 1 critical, 2 degraded)
ha_run_smoke() {
  local rc=0
  "$HA_SMOKE" "$@" || rc=$?
  return "$rc"
}

# ha_kv_get <file> <key>: value of KEY=VALUE in a backup manifest or migration record
ha_kv_get() {
  local line
  [[ -f $1 ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == "$2="* ]] && { printf '%s' "${line#*=}"; return 0; }
  done <"$1"
  return 1
}

# ha_confirm <prompt> <yes-flag>: interactive yes/no unless the flag is 1
ha_confirm() {
  [[ ${2:-0} == 1 ]] && return 0
  [[ -t 0 ]] || ql_die "$1 Re-run with --yes to confirm non-interactively."
  local a
  read -r -p "$1 [y/N] " a
  [[ $a == [yY] || $a == [yY][eE][sS] ]] || ql_die "aborted; nothing was changed"
}
