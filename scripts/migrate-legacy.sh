#!/usr/bin/env bash
# scripts/migrate-legacy.sh: adopt a hand-made Home Assistant container (`podman create/run` plus
# a hand-written systemd user unit) into the Quadlet deployment, in place, with a rollback.
#
#   scripts/migrate-legacy.sh --dry-run [--public-url URL]      report only; changes nothing
#   scripts/migrate-legacy.sh [--yes] [--public-url URL]        migrate
#   scripts/migrate-legacy.sh --rollback [<ts>] [--restore-config] [--yes]
#
#   --container NAME    the legacy container (default: homeassistant)
#   --legacy-unit UNIT  the unit that runs it (repeatable). Default: every
#                       ~/.config/systemd/user/*.service whose Exec lines name the container
#   --public-url URL    also check the public route before and after (manifest 200, /api/ 401)
#   --no-auto-rollback  keep the Quadlet deployment when the post-check fails critically
#   --allow-unhealthy   migrate even though the legacy HA fails its pre-flight checks
#
# Steps (all recorded in $HA_BACKUP_DIR/ha-pre-quadlet-<ts>/):
#   1. discover the container and its units; derive the settings from `podman inspect`:
#      /config bind -> HA_CONFIG_DIR, --privileged, --device (from the CreateCommand, because
#      podman drops devices under --privileged), TZ, /run/dbus. Refuses a non-host network,
#      mounts the unit would not carry, and an HA version other than this checkout's pin.
#   2. render and dry-run the unit with those settings; pull the pinned image while HA runs
#   3. pre-flight snapshot (tests/smoke.sh --legacy --snapshot): .storage entity, device and
#      ZHA counts, ports 8123/9584/21064, manifest.json 200, home-assistant.log ERROR count,
#      and with a smoke token the API state and config entries
#   4. graceful stop: the legacy unit, then `podman stop -t 300`; wait until the container,
#      port 8123 and the Zigbee radio are free
#   5. cold backup of the config dir (scripts/backup.sh --cold)
#   6. disable the legacy unit (the file stays) and rename the container to <name>-legacy-<ts>,
#      stopped and kept for rollback (Quadlet's `podman run --replace` would delete it)
#   7. write ~/.config/homeassistant/homeassistant.env and run scripts/install.sh
#   8. post-check: tests/smoke.sh --compare against the snapshot. A critical failure rolls back
#      automatically (unless --no-auto-rollback); degraded checks keep the migration, exit 2.
#
# --rollback [<ts>] (default: the newest migration) restores the legacy setup: stop and remove
# the Quadlet HA unit, rename the legacy container back, re-enable and start its unit, compare
# with the snapshot. --restore-config first puts the pre-migration cold backup back (only when
# the config dir itself is damaged; changes since the migration are lost). Never start the
# legacy unit while homeassistant.service is active: both would manage a container named
# "homeassistant".
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

name=$HA_CONTAINER dry=0 yes=0 public='' auto_rb=1 allow_unhealthy=0 rollback=0 rb_ts='' restore_cfg=0
legacy_override=()
while (($#)); do
  case $1 in
    --dry-run) dry=1 ;;
    --yes) yes=1 ;;
    --public-url) public=${2:?--public-url needs a URL}; public=${public%/}; shift ;;
    --container) name=${2:?--container needs a name}; shift ;;
    --legacy-unit) legacy_override+=("${2:?--legacy-unit needs a unit}"); shift ;;
    --no-auto-rollback) auto_rb=0 ;;
    --allow-unhealthy) allow_unhealthy=1 ;;
    --rollback)
      rollback=1
      if [[ ${2:-} != '' && ${2:-} != -* ]]; then rb_ts=$2; shift; fi
      ;;
    --restore-config) restore_cfg=1 ;;
    -h | --help) sed -n '2,41p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || ql_die "invalid container name '$name'"
[[ -z $rb_ts || $rb_ts =~ ^[0-9]{8}-[0-9]{6}$ ]] || ql_die "--rollback takes a timestamp like 20260912-013000"
((restore_cfg == 0 || rollback)) || ql_die "--restore-config goes with --rollback"

ql_preflight "$PODMAN_MIN"
command -v python3 >/dev/null 2>&1 || ql_die "python3 is required (sudo apt-get install python3)"
ha_lock
MIG_STATE=$HA_STATE_DIR/migrations

# ================================================================================================
# rollback
# ================================================================================================
# find_record [ts]: the migration's record dir (newest when ts is empty)
find_record() {
  local ts=$1 p root
  if [[ -z $ts ]]; then
    p=$(find "$MIG_STATE" -maxdepth 1 -name '*.path' -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tail -n1)
    [[ -n $p ]] || return 1
    ts=${p%.path}
  fi
  if [[ -f $MIG_STATE/$ts.path ]]; then
    cat -- "$MIG_STATE/$ts.path"
    return 0
  fi
  root=$(ql_expand_home "$(ql_env_get HA_BACKUP_DIR "%h/backups/$HA_APP")")
  [[ -d $root/ha-pre-quadlet-$ts ]] || return 1
  printf '%s\n' "$root/ha-pre-quadlet-$ts"
}

# do_rollback <record dir> <restore config 0|1>: put the legacy deployment back
do_rollback() {
  local B=$1 rcfg=$2 rec=$1/migration.env cname renamed enabled active running pub u lu rc=0
  [[ -f $rec ]] || ql_die "$rec not found"
  cname=$(ha_kv_get "$rec" CONTAINER)
  renamed=$(ha_kv_get "$rec" RENAMED || true)
  enabled=$(ha_kv_get "$rec" UNITS_ENABLED || true)
  active=$(ha_kv_get "$rec" UNITS_ACTIVE || true)
  running=$(ha_kv_get "$rec" WAS_RUNNING || echo 1)
  pub=$(ha_kv_get "$rec" PUBLIC_URL || true)
  ql_info "rolling back migration $(ha_kv_get "$rec" TS || echo '?'): container $cname, units: ${enabled:-none}"

  # 1. the Quadlet Home Assistant goes away; its config dir is the same one and stays
  if systemctl --user is-active --quiet "$HA_UNIT" 2>/dev/null; then
    ql_info "stopping $HA_UNIT (graceful, up to 300 s)"
    systemctl --user stop "$HA_UNIT" || ql_warn "systemctl --user stop $HA_UNIT failed"
  fi
  if ha_installed homeassistant.container; then
    ql_remove_files "$HA_APP" homeassistant.container
  fi
  systemctl --user reset-failed "$HA_UNIT" >/dev/null 2>&1 || true
  if ha_container_exists "$cname"; then
    lu=$(ha_container_unit "$cname")
    if [[ $lu == "$HA_UNIT" ]]; then
      podman rm -f -t 300 "$cname" >/dev/null || ql_die "cannot remove the Quadlet container $cname"
    elif [[ -n $renamed ]] && ha_container_exists "$renamed"; then
      ql_die "a container named $cname exists that is not the Quadlet one; cannot rename $renamed back"
    fi
  fi

  # 2. only on request: the pre-migration config dir (loses what changed since the migration)
  if ((rcfg)); then
    HA_ENV_FILE=$B/derived.env "$REPO/scripts/restore.sh" "$B/backup" --config-only --yes --aside-tag failed \
      || ql_die "restoring the config dir failed (see above); the legacy container was not started"
  fi

  # 3. the legacy container and its units come back
  if [[ -n $renamed ]] && ha_container_exists "$renamed"; then
    podman rename "$renamed" "$cname" || ql_die "podman rename $renamed $cname failed"
    ql_info "renamed $renamed back to $cname"
  fi
  for u in $enabled; do
    systemctl --user enable "$u" >/dev/null 2>&1 || ql_warn "could not enable $u"
  done
  if [[ -n $active ]]; then
    for u in $active; do
      ql_info "starting $u"
      systemctl --user start "$u" || ql_warn "could not start $u"
    done
  elif [[ $running == 1 ]]; then
    podman start "$cname" >/dev/null || ql_warn "could not start $cname"
  fi
  ql_env_set "$rec" STATUS rolled-back

  # 4. same checks as before the migration
  local -a args=(--legacy --wait 600 --compare "$B/preflight.json" --env "$B/derived.env")
  [[ -z $pub ]] || args+=(--public-url "$pub")
  ha_run_smoke "${args[@]}" || rc=$?
  case $rc in
    0) ql_info "rolled back: the legacy deployment passes the pre-migration checks" ;;
    2) ql_warn "rolled back; some degraded checks differ from before (see above)" ;;
    *) ql_warn "rolled back, but critical checks fail (see above). Last resort: $0 --rollback $(ha_kv_get "$rec" TS || true) --restore-config" ;;
  esac
  ql_info "the settings file $HA_ENV_FILE was left in place; install.sh refuses to run while ${enabled:-the legacy unit} is active or enabled"
  return "$rc"
}

if ((rollback)); then
  [[ ! -f $HA_ENV_FILE ]] || ql_env_load "$HA_ENV_FILE"
  B=$(find_record "$rb_ts") || ql_die "no migration record found${rb_ts:+ for $rb_ts}"
  ql_info "migration record: $B (status $(ha_kv_get "$B/migration.env" STATUS || echo '?'))"
  msg="Roll back to the legacy container?"
  ((restore_cfg)) && msg="Roll back to the legacy container AND restore the pre-migration config dir (changes since then are lost)?"
  ha_confirm "$msg" "$yes"
  rc=0
  do_rollback "$B" "$restore_cfg" || rc=$?
  exit "$rc"
fi

# ================================================================================================
# 1. discover
# ================================================================================================
ha_container_exists "$name" || ql_die "no container named $name: nothing to migrate (on a fresh host use scripts/install.sh)"
lu=$(ha_container_unit "$name")
if [[ $lu == "$HA_UNIT" ]]; then
  ql_info "$name is already managed by $HA_UNIT; nothing to migrate"
  exit 0
fi
[[ -z $lu ]] || ql_die "$name belongs to another systemd unit ($lu); migrate it by hand"
ha_installed homeassistant.container \
  && ql_die "a Quadlet homeassistant.container is already installed next to the legacy container; roll back or uninstall it first"
was_running=0
if ha_container_running "$name"; then was_running=1; fi
if ((${#legacy_override[@]})); then units=("${legacy_override[@]}"); else mapfile -t units < <(ha_legacy_units "$name"); fi
units_enabled=() units_active=()
for u in "${units[@]}"; do
  [[ -f $HA_SD_USER_DIR/$u || -n $(systemctl --user show -p FragmentPath --value "$u" 2>/dev/null) ]] || ql_die "unit $u not found"
  if [[ $(systemctl --user is-enabled "$u" 2>/dev/null || true) == enabled ]]; then units_enabled+=("$u"); fi
  if systemctl --user is-active --quiet "$u" 2>/dev/null; then units_active+=("$u"); fi
done
ql_info "legacy container $name ($( ((was_running)) && echo running || echo stopped)); units: ${units[*]:-none} (enabled: ${units_enabled[*]:-none}, active: ${units_active[*]:-none})"

# ================================================================================================
# 2. derive the settings
# ================================================================================================
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ha-migrate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
podman container inspect "$name" >"$WORK/inspect.json" || ql_die "podman inspect $name failed"
python3 - "$WORK/inspect.json" "$HOME" >"$WORK/derived.kv" <<'PY'
import json, sys

data = json.load(open(sys.argv[1]))
c = data[0] if isinstance(data, list) else data
home = sys.argv[2].rstrip("/")
hc, cf = c.get("HostConfig") or {}, c.get("Config") or {}
out, warn, fatal = {}, [], []

def home_rel(p):
    return "%h" + p[len(home):] if p == home or p.startswith(home + "/") else p

net = hc.get("NetworkMode") or ""
if net != "host":
    fatal.append(f"network mode is '{net}', not host: this migration keeps host networking; migrate by hand (docs/migrating.md)")
cfg_src, dbus, localtime, others = None, False, False, []
for m in c.get("Mounts") or []:
    dst, src, typ = m.get("Destination"), m.get("Source"), m.get("Type")
    if dst == "/config":
        if typ != "bind":
            fatal.append(f"/config is a {typ} ({m.get('Name') or src}), not a bind mount: copy it into a directory first")
        cfg_src = src
    elif dst == "/run/dbus":
        dbus = True
    elif dst == "/etc/localtime":
        localtime = True
    else:
        others.append(f"{src} -> {dst}")
if cfg_src is None:
    fatal.append("the container has no /config mount")
if others:
    fatal.append("mounts that the Quadlet unit would not carry: " + ", ".join(others))
out["HA_CONFIG_DIR"] = home_rel(cfg_src or "")
out["HA_PRIVILEGED"] = "true" if hc.get("Privileged") else "false"

# --device from the create command: rootless podman drops devices from HostConfig.Devices when
# --privileged is set, so the command line is the only record of the intended mapping.
cc, devs, i = cf.get("CreateCommand") or [], [], 0
while i < len(cc):
    a = cc[i]
    if a == "--device" and i + 1 < len(cc):
        devs.append(cc[i + 1])
        i += 2
        continue
    if a.startswith("--device="):
        devs.append(a.split("=", 1)[1])
    i += 1
for d in hc.get("Devices") or []:
    host = d.get("PathOnHost")
    if host and not any(x.split(":")[0] == host for x in devs):
        devs.append(f"{host}:{d.get('PathInContainer') or host}:{d.get('CgroupPermissions') or 'rwm'}")
if devs:
    first = devs[0].split(":")
    out["HA_ZIGBEE_DEVICE"] = first[0]
    out["HA_ZIGBEE_TARGET"] = first[1] if len(first) > 1 and first[1] else first[0]
    out["HA_EXTRA_DEVICES"] = " ".join(devs[1:])
else:
    out["HA_ZIGBEE_DEVICE"] = ""
    out["HA_EXTRA_DEVICES"] = ""

env = {}
for e in cf.get("Env") or []:
    k, _, v = e.partition("=")
    env[k] = v
tz = cf.get("Timezone") or env.get("TZ") or ("local" if localtime else "")
out["HA_TZ"] = tz
out["HA_BLUETOOTH"] = "true" if dbus else "false"
known = {"PATH", "LANG", "HOME", "HOSTNAME", "TERM", "container", "TZ"}
extra_env = sorted(k for k in env if k not in known and not k.startswith(("S6_", "UV_", "PIP_")))
if extra_env:
    warn.append("environment variables that are not carried over: " + ", ".join(extra_env))
if hc.get("CapAdd"):
    warn.append("added capabilities that are not carried over: " + ", ".join(hc["CapAdd"]))
out["IMAGE_ID"] = c.get("Image") or ""
out["IMAGE_NAME"] = c.get("ImageName") or ""
out["CREATE_COMMAND"] = " ".join(cc)
for k, v in out.items():
    print(f"{k}={v}")
for w in warn:
    print(f"WARN={w}")
for f in fatal:
    print(f"FATAL={f}")
PY
declare -A D=()
fatal=() warns=()
while IFS= read -r line; do
  k=${line%%=*} v=${line#*=}
  case $k in
    FATAL) fatal+=("$v") ;;
    WARN) warns+=("$v") ;;
    *) D[$k]=$v ;;
  esac
done <"$WORK/derived.kv"
for w in "${warns[@]}"; do ql_warn "$w"; done
if ((${#fatal[@]})); then
  printf '  %s\n' "${fatal[@]}" >&2
  ql_die "cannot migrate $name automatically"
fi

# version gate: same HA version on both sides, so no config migration happens in the cutover
legacy_ver=$(podman image inspect --format '{{index .Labels "io.hass.version"}}' "${D[IMAGE_ID]}" 2>/dev/null || true)
[[ $legacy_ver == '<no value>' ]] && legacy_ver=''
pin_img=$(ha_repo_image)
pin_ver=$(ha_image_version "$pin_img")
[[ -n $legacy_ver ]] || ql_die "cannot read the HA version (label io.hass.version) of ${D[IMAGE_NAME]:-the legacy image}"
if [[ $legacy_ver != "$pin_ver" ]]; then
  ql_die "the legacy container runs HA $legacy_ver and this checkout pins $pin_ver. Migrate at the same version (check out the tag that pins $legacy_ver, or upgrade the legacy container first), then use scripts/upgrade.sh"
fi
ql_info "version gate: legacy HA $legacy_ver = pinned $pin_ver"

# the settings file: the current one (or the example) with the derived values
base_env=$HA_ENV_FILE
[[ -f $base_env ]] || base_env=$REPO/config/$HA_APP.env.example
install -m 600 -- "$base_env" "$WORK/derived.env"
for k in HA_CONFIG_DIR HA_PRIVILEGED HA_ZIGBEE_DEVICE HA_ZIGBEE_TARGET HA_EXTRA_DEVICES HA_TZ HA_BLUETOOTH; do
  [[ -n ${D[$k]+x} ]] || continue
  ql_env_set "$WORK/derived.env" "$k" "${D[$k]}"
done
# The cutover adopts HA alone; Matter and Postgres come later with install.sh --with-...
ql_env_set "$WORK/derived.env" HA_MATTER false
ql_env_set "$WORK/derived.env" HA_POSTGRES false
ql_env_load "$WORK/derived.env"
ql_info "derived settings:"
for k in HA_CONFIG_DIR HA_PRIVILEGED HA_ZIGBEE_DEVICE HA_ZIGBEE_TARGET HA_EXTRA_DEVICES HA_TZ HA_BLUETOOTH; do
  printf '    %s=%s\n' "$k" "$(ql_env_get "$k" '')" >&2
done
if [[ -f $HA_ENV_FILE ]] && ! cmp -s -- "$HA_ENV_FILE" "$WORK/derived.env"; then
  ql_warn "$HA_ENV_FILE will be replaced by the derived settings (a copy is kept). Difference:"
  diff -u -- "$HA_ENV_FILE" "$WORK/derived.env" | sed 's/^/    /' >&2 || true
fi
ha_check_config_dir
ha_check_devices
port=$(ql_env_get HA_PORT 8123)

# ================================================================================================
# 2b. render and dry-run the unit; pull the image while HA still runs
# ================================================================================================
mkdir -p "$WORK/src" "$WORK/out" "$WORK/gen"
cp -p "$REPO/quadlet/homeassistant.container" "$WORK/src/"
if ! (
  RENDER_ARGS=()
  render_args "$WORK/derived.env"
  ql_render "$WORK/src" "$WORK/derived.env" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
  ql_dryrun "$WORK/out" --verify --ref-dir "$HA_QUADLET_DIR" --keep "$WORK/gen"
); then
  ql_die "the rendered unit fails the Quadlet dry-run; nothing was changed"
fi
ql_info "legacy create command:"
printf '    %s\n' "${D[CREATE_COMMAND]}" >&2
ql_info "Quadlet will run:"
sed -n 's/^ExecStart=/    /p' "$WORK/gen/homeassistant.service" >&2
if ((dry)); then
  if podman image exists "$pin_img"; then ql_info "image $pin_img is present"; else ql_info "image $pin_img would be pulled before the stop"; fi
else
  ql_pull_images "$WORK/out"
fi
pin_id=$(podman image inspect --format '{{.Id}}' "$pin_img" 2>/dev/null || true)
if [[ -n $pin_id && $pin_id == "${D[IMAGE_ID]}" ]]; then
  ql_info "the pinned image is the image the legacy container runs (tag-only change)"
fi

# ================================================================================================
# 3. pre-flight snapshot
# ================================================================================================
[[ -r ${HA_SMOKE_HEADER:-$HOME/.config/$HA_APP/smoke.header} ]] \
  || ql_warn "no smoke token (~/.config/$HA_APP/smoke.header): the config-entry and entity comparisons are skipped (docs/migrating.md)"
sargs=(--legacy --snapshot "$WORK/preflight.json" --env "$WORK/derived.env")
[[ -z $public ]] || sargs+=(--public-url "$public")
rc=0
ha_run_smoke "${sargs[@]}" || rc=$?
if ((rc == 1)); then
  ((allow_unhealthy)) || ql_die "the legacy Home Assistant fails its pre-flight checks (see above); fix that first, or add --allow-unhealthy"
  ql_warn "--allow-unhealthy: migrating although the pre-flight checks fail"
fi

if ((dry)); then
  cat >&2 <<EOF
migrate-legacy: dry run complete; nothing was changed. A real run would:
    - stop ${units_active[*]:-the container} and then $name (podman stop -t 300)
    - cold-back up $(ha_config_dir) into $(ha_backup_root)/ha-pre-quadlet-<ts>/backup
    - disable ${units_enabled[*]:-no unit} (files kept) and rename $name to $name-legacy-<ts>
    - write $HA_ENV_FILE and run scripts/install.sh
    - compare with the pre-flight snapshot${public:+ (and $public)}; roll back on a critical failure
EOF
  exit 0
fi

# ================================================================================================
# the real run
# ================================================================================================
ha_confirm "Migrate $name to Quadlet now? Home Assistant is down for about 5 minutes." "$yes"
ts=$(ha_ts)
root=$(ha_backup_root)
B=$root/ha-pre-quadlet-$ts
(umask 077 && mkdir -p -- "$B/legacy") || ql_die "cannot create $B"
install -m 600 -- "$WORK/derived.env" "$B/derived.env"
install -m 600 -- "$WORK/preflight.json" "$B/preflight.json"
install -m 600 -- "$WORK/inspect.json" "$B/legacy/inspect.json"
podman container inspect --format '{{json .Config.CreateCommand}}' "$name" >"$B/legacy/createcommand.json"
for u in "${units[@]}"; do
  [[ ! -f $HA_SD_USER_DIR/$u ]] || cp -p -- "$HA_SD_USER_DIR/$u" "$B/legacy/"
done
{
  printf 'TS=%s\n' "$ts"
  printf 'CONTAINER=%s\n' "$name"
  printf 'RENAMED=\n'
  printf 'UNITS=%s\n' "${units[*]}"
  printf 'UNITS_ENABLED=%s\n' "${units_enabled[*]}"
  printf 'UNITS_ACTIVE=%s\n' "${units_active[*]}"
  printf 'WAS_RUNNING=%s\n' "$was_running"
  printf 'CONFIG_DIR=%s\n' "$(ql_env_get HA_CONFIG_DIR)"
  printf 'LEGACY_IMAGE=%s\n' "${D[IMAGE_NAME]}"
  printf 'PINNED_IMAGE=%s\n' "$pin_img"
  printf 'PUBLIC_URL=%s\n' "$public"
  printf 'STATUS=started\n'
} >"$B/migration.env"
chmod 600 -- "$B/migration.env"
(umask 077 && mkdir -p -- "$MIG_STATE") && printf '%s\n' "$B" >"$MIG_STATE/$ts.path"
exec > >(tee -a "$B/migrate.log") 2>&1
ql_info "migration $ts; record and backups in $B"
REC=$B/migration.env

# these three are called by name through ql_wait_until
# shellcheck disable=SC2329
not_running() { ! ha_container_running "$1"; }
# shellcheck disable=SC2329
port_free() { [[ -z $(ss -Hltn "sport = :$1" 2>/dev/null) ]]; }
# shellcheck disable=SC2329
radio_free() { [[ -z $(ha_device_holders "$1") ]]; }
# restart_legacy: undo the stop, before anything else was changed
restart_legacy() {
  local u
  ql_warn "starting the legacy deployment again, unchanged"
  for u in "${units_active[@]}"; do systemctl --user start "$u" || ql_warn "could not start $u"; done
  if ((${#units_active[@]} == 0 && was_running)); then podman start "$name" >/dev/null || ql_warn "could not start $name"; fi
  ql_env_set "$REC" STATUS aborted
}
fail() {
  ql_warn "$1"
  ql_env_set "$REC" STATUS failed
  if ((auto_rb)); then
    ql_warn "rolling back automatically (--no-auto-rollback keeps the Quadlet deployment for debugging)"
    do_rollback "$B" 0 || true
    ql_die "the migration failed and was rolled back: $1"
  fi
  ql_die "the migration failed: $1. The Quadlet deployment is left as it is; roll back with: $0 --rollback $ts"
}

# ---- 4. graceful stop -------------------------------------------------------------------------
for u in "${units_active[@]}"; do
  ql_info "stopping $u"
  systemctl --user stop "$u" || ql_warn "systemctl --user stop $u failed"
done
if ha_container_running "$name"; then
  ql_info "stopping $name (graceful, up to 300 s)"
  podman stop -t 300 "$name" >/dev/null || ql_warn "podman stop $name reported an error"
fi
ql_wait_until 60 "container $name to stop" not_running "$name" || { restart_legacy; ql_die "$name did not stop"; }
ql_wait_until 60 "port $port to be released" port_free "$port" || { restart_legacy; ql_die "port $port is still in use"; }
for p in 21064 9584; do
  ql_wait_until 30 "port $p to be released" port_free "$p" || ql_warn "port $p is still in use by something else"
done
dev=$(ql_env_get HA_ZIGBEE_DEVICE '')
if [[ -n $dev ]]; then
  ql_wait_until 30 "the radio $dev to be released" radio_free "$dev" \
    || { restart_legacy; ql_die "the radio is still held by pid(s) $(ha_device_holders "$dev" | tr '\n' ' ')"; }
fi
ql_env_set "$REC" STATUS stopped

# ---- 5. cold backup ---------------------------------------------------------------------------
if ! HA_ENV_FILE=$B/derived.env "$REPO/scripts/backup.sh" --cold --dest "$B/backup" --no-prune >/dev/null; then
  restart_legacy
  ql_die "the cold backup failed; the legacy deployment runs again, nothing else was changed"
fi
ql_env_set "$REC" STATUS backed-up

# ---- 6. disable the legacy unit, rename the container ------------------------------------------
for u in "${units_enabled[@]}"; do
  systemctl --user disable "$u" >/dev/null 2>&1 || ql_warn "could not disable $u"
  ql_info "disabled $u (the file stays in $HA_SD_USER_DIR)"
done
renamed=$name-legacy-$ts
if ! podman rename "$name" "$renamed"; then
  for u in "${units_enabled[@]}"; do systemctl --user enable "$u" >/dev/null 2>&1 || true; done
  restart_legacy
  ql_die "podman rename failed; the legacy deployment runs again"
fi
ql_env_set "$REC" RENAMED "$renamed"
ql_env_set "$REC" STATUS renamed
ql_info "renamed $name to $renamed (stopped, kept for rollback)"

# ---- 7. settings file and install -------------------------------------------------------------
if [[ -f $HA_ENV_FILE ]] && ! cmp -s -- "$HA_ENV_FILE" "$B/derived.env"; then
  cp -p -- "$HA_ENV_FILE" "$B/homeassistant.env.before"
fi
(umask 077 && mkdir -p -- "$(dirname -- "$HA_ENV_FILE")")
install -m 600 -- "$B/derived.env" "$HA_ENV_FILE"
ql_info "wrote $HA_ENV_FILE"
if ! "$REPO/scripts/install.sh" --no-smoke; then
  fail "scripts/install.sh failed"
fi
ql_env_set "$REC" STATUS installed

# ---- 8. post-check against the snapshot --------------------------------------------------------
sargs=(--wait 900 --compare "$B/preflight.json")
[[ -z $public ]] || sargs+=(--public-url "$public")
rc=0
ha_run_smoke "${sargs[@]}" || rc=$?
((rc == 1)) && fail "critical post-migration checks failed"
if ((rc == 0)); then ql_env_set "$REC" STATUS 'done'; else ql_env_set "$REC" STATUS done-degraded; fi
cat <<EOF

Migration $ts done$( ((rc == 2)) && printf ' with degraded checks (see above)').
  legacy container:  $renamed (stopped, kept for rollback)
  legacy units:      ${units_enabled[*]:-none} disabled; files kept in $HA_SD_USER_DIR
  backup + snapshot: $B
  soak check:        $REPO/tests/smoke.sh --compare $B/preflight.json${public:+ --public-url $public}
  roll back:         $0 --rollback $ts
Do not start ${units_enabled[*]:-the legacy unit} while $HA_UNIT is active.
EOF
exit "$rc"
