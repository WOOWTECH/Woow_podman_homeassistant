#!/usr/bin/env bash
# tests/scripts-test.sh: end-to-end tests for scripts/*.sh against the doubles in tests/shims
# (podman, systemctl, loginctl, ss, curl). No container is ever created and the real user manager
# is never touched: each test gets its own HOME, shim state and copy of this repo. The Quadlet
# generator and systemd-analyze are the real ones; they only read unit files.
#
#   tests/scripts-test.sh [name-filter]
#
# Each test runs in a subshell under `set -euo pipefail`, the mode the scripts use.
# shellcheck disable=SC2030,SC2031 # every test has its own subshell, so "modified in a subshell" does not apply
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ha-scripts-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0 nskip=0
FAILED=()
PIN_IMAGE=$(sed -n 's/^Image=//p' "$REPO/quadlet/homeassistant.container" | tail -n1)
PIN_VER=${PIN_IMAGE##*:}

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2]"; }
calls() { cat "$SHIM_STATE/calls"; }
ncalls() { grep -cF -- "$1" "$SHIM_STATE/calls" || true; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }
expect_rc() {
  local want=$1 rc=0
  shift
  OUT=$( ("$@") 2>&1) || rc=$?
  [[ $rc == "$want" ]] || die_t "expected exit $want, got $rc, from: $*"$'\n'"$OUT"
}
skip() { echo "SKIP: $*"; exit 77; }
Q() { printf '%s' "$HOME/.config/containers/systemd"; }
SD() { printf '%s' "$HOME/.config/systemd/user"; }
ENVF() { printf '%s' "$HOME/.config/homeassistant/homeassistant.env"; }

# ---- fixtures ---------------------------------------------------------------------------------
mk_repo() { # a private copy of the repo, so a test may change the pinned version
  mkdir -p "$T/repo"
  tar -C "$REPO" --exclude=./.git -cf - . | tar -C "$T/repo" -xf -
  R=$T/repo
}
mk_config_dir() { # a config dir that looks like a small Home Assistant
  CFG=$HOME/ha-config
  mkdir -p "$CFG/.storage"
  printf '%s\n' "$PIN_VER" >"$CFG/.HA_VERSION"
  printf 'default_config:\n' >"$CFG/configuration.yaml"
  python3 - "$CFG" <<'PY'
import json, os, sqlite3, sys
cfg = sys.argv[1]
st = os.path.join(cfg, ".storage")
ents = [{"entity_id": f"light.l{i}", "disabled_by": None} for i in range(3)]
json.dump({"version": 1, "data": {"entities": ents}}, open(os.path.join(st, "core.entity_registry"), "w"))
devs = [{"id": "d1", "identifiers": [["zha", "00:11"]]}, {"id": "d2", "identifiers": [["hue", "x"]]}]
json.dump({"version": 1, "data": {"devices": devs}}, open(os.path.join(st, "core.device_registry"), "w"))
entries = [{"entry_id": "e1", "domain": "zha", "title": "ZHA"}, {"entry_id": "e2", "domain": "homekit", "title": "HomeKit"}]
json.dump({"version": 1, "data": {"entries": entries}}, open(os.path.join(st, "core.config_entries"), "w"))
con = sqlite3.connect(os.path.join(cfg, "home-assistant_v2.db"))
con.execute("create table states (id integer primary key, v text)")
con.executemany("insert into states (v) values (?)", [(f"s{i}",) for i in range(50)])
con.commit()
con.close()
PY
  printf '2026-09-12 00:00:00.1 ERROR (MainThread) [x] boom 12\n' >"$CFG/home-assistant.log"
}
mk_env() { # mk_env [KEY=VALUE...]
  local kv
  mkdir -p "$HOME/.config/homeassistant"
  install -m 600 "$R/config/homeassistant.env.example" "$(ENVF)"
  for kv in "$@"; do
    grep -v "^${kv%%=*}=" "$(ENVF)" >"$(ENVF).t" || true
    printf '%s\n' "$kv" >>"$(ENVF).t"
    mv -f "$(ENVF).t" "$(ENVF)"
  done
  chmod 600 "$(ENVF)"
}
mk_image() { # mk_image REF [hass-version] [id]
  mkdir -p "$SHIM_STATE/images"
  python3 - "$SHIM_STATE" "$1" "${2:-}" "${3:-}" <<'PY'
import json, os, sys
state, ref, ver, iid = sys.argv[1:5]
key = ref.replace("/", "_").replace(":", "_").replace("@", "_")
data = {"ref": ref, "id": iid or ("sha256:" + key), "labels": {}}
if ver:
    data["labels"]["io.hass.version"] = ver
json.dump(data, open(os.path.join(state, "images", key + ".json"), "w"))
PY
}
mk_container() { # mk_container NAME [key=value ...] (label image config_src privileged network devices tz running ports stop_timeout restart sizerw)
  mkdir -p "$SHIM_STATE/containers/$1"
  python3 - "$SHIM_STATE" "$@" <<'PY'
import json, os, sys
state, name = sys.argv[1], sys.argv[2]
opt = dict(a.split("=", 1) for a in sys.argv[3:])
devices = opt.get("devices", "").split() if opt.get("devices") else []
cc = ["podman", "create", "--name", name]
if opt.get("privileged", "true") == "true":
    cc.append("--privileged")
cc += ["--network", opt.get("network", "host")]
for d in devices:
    cc += ["--device", d]
mounts = []
if opt.get("config_src"):
    mounts.append({"Type": "bind", "Source": opt["config_src"], "Destination": "/config"})
    cc += ["-v", opt["config_src"] + ":/config"]
for extra in opt.get("mounts", "").split():
    src, dst = extra.split(":")
    mounts.append({"Type": "bind", "Source": src, "Destination": dst})
cc.append(opt.get("image", "ghcr.io/home-assistant/home-assistant:stable"))
labels = {}
if opt.get("label"):
    labels["PODMAN_SYSTEMD_UNIT"] = opt["label"]
obj = {
    "Name": name,
    "Id": "cid-" + name,
    "SizeRw": int(opt.get("sizerw", "48151168")),
    "Image": opt.get("image_id", "sha256:legacy"),
    "ImageName": opt.get("image", "ghcr.io/home-assistant/home-assistant:stable"),
    "State": {"Running": opt.get("running", "true") == "true",
              "Status": "running" if opt.get("running", "true") == "true" else "exited",
              "StartedAt": "2026-09-12T00:00:00Z",
              "Health": {"Status": opt.get("health", "healthy")} if opt.get("health") else None},
    "Config": {"Labels": labels, "CreateCommand": cc, "Env": ["PATH=/usr/bin", "S6_SERVICES_GRACETIME=240000"],
               "StopTimeout": int(opt.get("stop_timeout", "300")), "Timezone": opt.get("tz", ""),
               "Healthcheck": {"Test": ["CMD", "true"]} if opt.get("health") else None},
    "HostConfig": {"NetworkMode": opt.get("network", "host"),
                   "Privileged": opt.get("privileged", "true") == "true", "Devices": [],
                   "AutoRemove": False,
                   # the restart policy podman records on the container object. A legacy HA
                   # started by a hand-written unit usually has "unless-stopped"; "always" is
                   # the one podman-restart.service revives at boot.
                   "RestartPolicy": {"Name": opt.get("restart", "unless-stopped"),
                                     "MaximumRetryCount": 0}},
    "NetworkSettings": {"Networks": {} if opt.get("network", "host") == "host"
                        else {opt.get("network", "host"): {"Aliases": [], "IPAddress": "", "MacAddress": ""}},
                        "Ports": {}},
    "Mounts": mounts,
}
json.dump([obj], open(os.path.join(state, "containers", name, "inspect.json"), "w"))
d = os.path.join(state, "containers", name, "devices")
with open(d, "w") as f:
    for spec in devices:
        parts = spec.split(":")
        f.write((parts[1] if len(parts) > 1 else parts[0]) + "\n")
with open(os.path.join(state, "containers", name, "ports"), "w") as f:
    ports = opt.get("ports", "")
    f.write(ports + "\n" if ports and not ports.endswith("\n") else ports)
PY
  sync_ports
}
sync_ports() { # listeners of the running containers, for the ss shim
  : >"$SHIM_STATE/ports"
  local d
  for d in "$SHIM_STATE"/containers/*/; do
    [[ -d $d ]] || continue
    [[ -f $d/ports ]] || continue
    [[ $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["State"]["Running"])' "$d/inspect.json") == True ]] || continue
    cat "$d/ports" >>"$SHIM_STATE/ports"
  done
}
mk_legacy_unit() { # a hand-written unit that runs the legacy container, enabled and active
  mkdir -p "$(SD)"
  cat >"$(SD)/podman-ha.service" <<'EOF'
[Unit]
Description=Home Assistant (legacy)
[Service]
ExecStartPre=-podman stop homeassistant
ExecStart=podman start -a homeassistant
Restart=on-failure
[Install]
WantedBy=default.target
EOF
  mkdir -p "$SHIM_STATE/units/podman-ha.service"
  echo enabled >"$SHIM_STATE/units/podman-ha.service/UnitFileState"
  echo active >"$SHIM_STATE/units/podman-ha.service/active"
}
set_http() { # set_http URL CODE [BODY]
  mkdir -p "$SHIM_STATE/http"
  local key=${1//[^A-Za-z0-9]/_}
  { printf '%s\n' "$2"; [[ $# -lt 3 ]] || printf '%s' "$3"; } >"$SHIM_STATE/http/$key"
}
smoke_stub() { # smoke_stub RC...: fake tests/smoke.sh that logs its arguments
  printf '%s\n' "$@" >"$T/smoke-rc"
  cat >"$T/smoke-stub" <<'EOF'
#!/usr/bin/env bash
printf 'smoke %s\n' "$*" >>"$SHIM_STATE/smoke-args"
rc=0
if [[ -s $SMOKE_RC ]]; then
  rc=$(head -n1 "$SMOKE_RC")
  (($(wc -l <"$SMOKE_RC") > 1)) && sed -i 1d "$SMOKE_RC"
fi
for a in "$@"; do
  [[ $prev == --snapshot ]] && printf '{"format":1,"facts":{"mode":"legacy"},"storage":{},"zigpy":{},"log":{},"api":null}\n' >"$a"
  prev=$a
done
# SMOKE_HOOK runs after every call with the exit code it is about to return, so a test can
# damage the deployment exactly when the run reaches that check (no sleeps, no races).
[[ -n ${SMOKE_HOOK:-} && -x ${SMOKE_HOOK:-} ]] && "$SMOKE_HOOK" "$rc"
exit "$rc"
EOF
  chmod +x "$T/smoke-stub"
  export HA_SMOKE_CMD=$T/smoke-stub SMOKE_RC=$T/smoke-rc
  : >"$SHIM_STATE/smoke-args"
}
smoke_args() { cat "$SHIM_STATE/smoke-args" 2>/dev/null || true; }
installed_image() { sed -n 's/^Image=//p' "$(Q)/homeassistant.container" | tail -n1; }

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run" "$T/linger" "$T/etc-user" "$T/tmp"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run TMPDIR=$T/tmp
    export PATH="$SHIMS:$PATH" QL_LINGER_DIR=$T/linger QL_SHADOW_DIRS=$T/etc-user
    export QL_POLL_INTERVAL=0.05 HA_SMOKE_MDNS='' HA_SMOKE_POLL=1
    unset XDG_CONFIG_HOME XDG_STATE_HOME QL_APP QL_DRY_RUN HA_SMOKE_CMD HA_ENV_FILE QL_QUADLET_DIR
    : >"$SHIM_STATE/calls"
    echo yes >"$SHIM_STATE/linger"
    [[ $(command -v podman) == "$SHIMS/podman" && $(command -v systemctl) == "$SHIMS/systemctl" ]] \
      || die_t "shims are not first on PATH; refusing to run"
    R='' CFG=''
    "$t"
  ) >"$log" 2>&1
  rc=$?
  case $rc in
    0) npass=$((npass + 1)); printf 'ok    %s\n' "$t" ;;
    77) nskip=$((nskip + 1)); printf 'skip  %s (%s)\n' "$t" "$(grep -m1 '^SKIP:' "$log" | cut -c7-)" ;;
    *) nfail=$((nfail + 1)); FAILED+=("$t"); printf 'FAIL  %s\n' "$t"; tail -n 40 "$log" | sed 's/^/      | /' ;;
  esac
}
need_quadlet() {
  [[ -x ${QL_QUADLET_BIN:-/usr/libexec/podman/quadlet} ]] || skip "no Quadlet generator"
  command -v systemd-analyze >/dev/null || skip "no systemd-analyze"
}

# ================================================================================================
# install.sh
# ================================================================================================
t_install_first_run_creates_the_settings_file() {
  need_quadlet
  mk_repo
  expect_ok "$R/scripts/install.sh"
  has "$OUT" "review $(ENVF)"
  eq "$(stat -c %a "$(ENVF)")" 600 "settings file mode"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "nothing may be installed on the first run"
}

t_install_saves_the_optional_selection_on_the_first_run() {
  need_quadlet
  mk_repo
  expect_ok "$R/scripts/install.sh" --with-matter
  grep -qx 'HA_MATTER=true' "$(ENVF)" || die_t "--with-matter was not saved"
}

t_install_refuses_a_legacy_container() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG"
  mk_container homeassistant "config_src=$CFG" ports='tcp 8123 python3 4242'
  expect_fail "$R/scripts/install.sh" --no-smoke
  has "$OUT" "podman rename homeassistant homeassistant-legacy-"
  has "$OUT" "scripts/migrate-legacy.sh"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "must not install next to a legacy container"
}

t_install_refuses_an_active_legacy_unit() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG"
  mk_legacy_unit
  expect_fail "$R/scripts/install.sh" --no-smoke
  has "$OUT" "legacy unit podman-ha.service is running"
}

t_install_refuses_an_enabled_legacy_unit() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG"
  mk_legacy_unit
  echo inactive >"$SHIM_STATE/units/podman-ha.service/active"
  expect_fail "$R/scripts/install.sh" --no-smoke
  has "$OUT" "is enabled"
}

t_install_refuses_a_privileged_device_mismatch() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG" HA_PRIVILEGED=true HA_ZIGBEE_DEVICE=/dev/null HA_ZIGBEE_TARGET=/dev/ttyACM0
  expect_fail "$R/scripts/install.sh" --no-smoke
  has "$OUT" "podman ignores the mapping"
  # the same device with a matching target is fine
  mk_env "HA_CONFIG_DIR=$CFG" HA_PRIVILEGED=true HA_ZIGBEE_DEVICE=/dev/null HA_ZIGBEE_TARGET=/dev/null
  expect_ok "$R/scripts/install.sh" --no-smoke
  grep -qx 'AddDevice=/dev/null:/dev/null:rwm' "$(Q)/homeassistant.container" || die_t "device line not rendered"
}

t_install_then_idempotent_rerun_then_change() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG" HA_TZ=local
  smoke_stub 0
  expect_ok "$R/scripts/install.sh"
  has "$OUT" "installed and healthy"
  grep -qx "Volume=$CFG:/config:rw" "$(Q)/homeassistant.container" || die_t "config dir not rendered"
  grep -qx 'Timezone=local' "$(Q)/homeassistant.container" || die_t "time zone not rendered"
  has "$(calls)" "podman pull $PIN_IMAGE"
  has "$(calls)" "systemctl --user restart homeassistant.service"
  has "$(smoke_args)" "--wait 900"
  # nothing changed: nothing is pulled, started or restarted
  : >"$SHIM_STATE/calls"
  expect_ok "$R/scripts/install.sh"
  eq "$(ncalls 'systemctl --user restart')$(ncalls 'systemctl --user start')$(ncalls 'podman pull')" 000 "idempotent re-run"
  # a settings change restarts Home Assistant
  mk_env "HA_CONFIG_DIR=$CFG" HA_TZ=Asia/Taipei
  : >"$SHIM_STATE/calls"
  expect_ok "$R/scripts/install.sh"
  has "$OUT" "changed: homeassistant.container"
  eq "$(ncalls 'systemctl --user restart homeassistant.service')" 1 "restarted after the change"
  grep -qx 'Timezone=Asia/Taipei' "$(Q)/homeassistant.container" || die_t "new time zone not rendered"
}

t_install_adds_and_removes_the_matter_option() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG"
  smoke_stub 0 0 0
  expect_ok "$R/scripts/install.sh"
  : >"$SHIM_STATE/calls"
  expect_ok "$R/scripts/install.sh" --with-matter
  [[ -f $(Q)/homeassistant-matter.container && -f $(Q)/homeassistant-matter-data.volume ]] || die_t "Matter units not installed"
  eq "$(ncalls 'systemctl --user restart homeassistant.service')" 0 "adding Matter must not restart Home Assistant"
  has "$(calls)" "homeassistant-matter.service" "the Matter unit must be started"
  : >"$SHIM_STATE/calls"
  expect_ok "$R/scripts/install.sh" --without-matter
  [[ ! -e $(Q)/homeassistant-matter.container ]] || die_t "Matter unit not removed"
  has "$(calls)" "systemctl --user stop homeassistant-matter.service"
  grep -qx 'HA_MATTER=false' "$(ENVF)" || die_t "--without-matter was not saved"
}

t_install_refuses_a_version_change() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG"
  smoke_stub 0
  expect_ok "$R/scripts/install.sh"
  sed -i "s|^Image=.*|Image=ghcr.io/home-assistant/home-assistant:2027.1.0|" "$R/quadlet/homeassistant.container"
  expect_fail "$R/scripts/install.sh"
  has "$OUT" "scripts/upgrade.sh"
  eq "$(installed_image)" "$PIN_IMAGE" "the installed image must not change"
}

# ================================================================================================
# backup.sh / restore.sh
# ================================================================================================
t_backup_hot_then_restore_round_trip() {
  need_quadlet
  setup_installed # restore.sh starts the installed units again, so this needs a real install
  echo marker >"$CFG/marker.txt"
  local bdir
  bdir=$("$R/scripts/backup.sh" --hot 2>"$T/err" | tail -n1) || { cat "$T/err"; die_t "hot backup failed"; }
  [[ -f $bdir/config.tgz && -f $bdir/sqlite/home-assistant_v2.db.gz && -f $bdir/SHA256SUMS ]] \
    || die_t "backup is incomplete: $(ls -R "$bdir")"
  (cd "$bdir" && sha256sum -c --quiet SHA256SUMS) || die_t "checksums do not verify"
  tar -tzf "$bdir/config.tgz" | grep -q 'ha-config/home-assistant_v2.db' && die_t "the live database must not be in the archive"
  eq "$(sed -n 's/^MODE=//p' "$bdir/manifest.env")" hot "backup mode"
  # restore over a damaged config dir; restore.sh stops the unit itself
  rm -f "$CFG/marker.txt"
  echo broken >"$CFG/.storage/core.entity_registry"
  smoke_stub 0
  expect_ok "$R/scripts/restore.sh" "$bdir" --yes
  has "$(calls)" "systemctl --user stop homeassistant.service"
  eq "$(cat "$SHIM_STATE/units/homeassistant.service/active")" active "HA must run again after the restore"
  eq "$(cat "$CFG/marker.txt")" marker "the restored file"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CFG/.storage/core.entity_registry" || die_t "registry not restored"
  ls -d "$CFG".pre-restore-* >/dev/null || die_t "the previous config dir was not kept"
}

t_restore_refuses_an_older_backup_without_with_unit() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG"
  mk_container homeassistant label=homeassistant.service "config_src=$CFG" image="$PIN_IMAGE" running=false
  local bdir
  bdir=$("$R/scripts/backup.sh" --cold 2>/dev/null | tail -n1)
  sed -i 's/^HA_VERSION=.*/HA_VERSION=2020.1.0/' "$bdir/manifest.env"
  # the checksum file is written outside the backup dir: the shell creates it before find runs
  (cd "$bdir" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort \
    | xargs -r -d '\n' sha256sum -- >"$T/sums" && mv "$T/sums" SHA256SUMS)
  expect_fail "$R/scripts/restore.sh" "$bdir" --yes
  has "$OUT" "older than"
}

# ================================================================================================
# uninstall.sh
# ================================================================================================
t_uninstall_keeps_data_and_purge_deletes_it() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG"
  smoke_stub 0 0
  expect_ok "$R/scripts/install.sh" --with-matter
  mkdir -p "$SHIM_STATE/volumes/homeassistant-matter-data"
  echo data >"$SHIM_STATE/volumes/homeassistant-matter-data/fabric.json"
  expect_ok "$R/scripts/uninstall.sh"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "units not removed"
  [[ -d $SHIM_STATE/volumes/homeassistant-matter-data && -d $CFG && -f $(ENVF) ]] || die_t "data must be kept"
  expect_ok "$R/scripts/install.sh" --with-matter
  expect_fail "$R/scripts/uninstall.sh" --purge </dev/null
  has "$OUT" "add --yes"
  expect_ok "$R/scripts/uninstall.sh" --purge --yes
  [[ ! -d $SHIM_STATE/volumes/homeassistant-matter-data ]] || die_t "volume not purged"
  [[ -d $CFG ]] || die_t "the config dir must survive --purge without --delete-config"
  ls -d "$HOME"/backups/homeassistant/ha-pre-purge-* >/dev/null || die_t "no final export before the purge"
  # and with --delete-config it goes, after an archive
  expect_ok "$R/scripts/install.sh"
  expect_fail "$R/scripts/uninstall.sh" --purge --yes --delete-config=/wrong/path
  expect_ok "$R/scripts/uninstall.sh" --purge --yes "--delete-config=$CFG"
  [[ ! -d $CFG ]] || die_t "the config dir was not deleted"
  ls "$HOME"/backups/homeassistant/ha-pre-purge-*/config.tgz >/dev/null || die_t "no archive of the config dir"
}

# ================================================================================================
# upgrade.sh
# ================================================================================================
setup_installed() { # a working installation with HA "running"
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG"
  smoke_stub 0
  "$R/scripts/install.sh" >/dev/null 2>&1 || die_t "install failed"
  mk_container homeassistant label=homeassistant.service "config_src=$CFG" image="$PIN_IMAGE" ports='tcp 8123 python3 4242'
  set_http http://127.0.0.1:8123/manifest.json 200
}

t_upgrade_moves_to_the_new_pin() {
  need_quadlet
  setup_installed
  sed -i "s|^Image=.*|Image=ghcr.io/home-assistant/home-assistant:2027.1.0|" "$R/quadlet/homeassistant.container"
  smoke_stub 0 0
  expect_ok "$R/scripts/upgrade.sh" --yes
  eq "$(installed_image)" ghcr.io/home-assistant/home-assistant:2027.1.0 "installed image after the upgrade"
  has "$(calls)" "podman pull ghcr.io/home-assistant/home-assistant:2027.1.0"
  has "$(calls)" "systemctl --user stop homeassistant.service"
  ls -d "$HOME"/backups/homeassistant/ha-pre-upgrade-*/backup/config.tgz >/dev/null || die_t "no cold backup"
  has "$(smoke_args)" "--compare"
}

t_upgrade_rolls_back_when_the_post_check_fails() {
  need_quadlet
  setup_installed
  echo marker >"$CFG/marker.txt"
  sed -i "s|^Image=.*|Image=ghcr.io/home-assistant/home-assistant:2027.1.0|" "$R/quadlet/homeassistant.container"
  # snapshot ok, post-upgrade check critical, rollback check ok
  smoke_stub 0 1 0
  # the "new version" damages the config dir, as a failed migration would: at the post-upgrade
  # check, which is after the cold backup and before the rollback
  cat >"$T/damage" <<EOF
#!/usr/bin/env bash
[[ \$1 == 1 ]] && rm -f "$CFG/marker.txt"
exit 0
EOF
  chmod +x "$T/damage"
  export SMOKE_HOOK=$T/damage
  expect_rc 1 "$R/scripts/upgrade.sh" --yes
  unset SMOKE_HOOK
  has "$OUT" "ROLLING BACK"
  eq "$(installed_image)" "$PIN_IMAGE" "the old image must be back"
  eq "$(cat "$CFG/marker.txt")" marker "the config dir must be restored from the cold backup"
  ls -d "$CFG".failed-* >/dev/null || die_t "the failed config dir was not kept"
}

# ================================================================================================
# migrate-legacy.sh
# ================================================================================================
setup_legacy() { # the toypark1234 shape: privileged, host network, a by-id device, its own unit
  mk_repo
  mk_config_dir
  mk_image ghcr.io/home-assistant/home-assistant:stable "$PIN_VER" sha256:legacy
  mk_image "$PIN_IMAGE" "$PIN_VER" sha256:legacy
  mk_container homeassistant "config_src=$CFG" privileged=true network=host \
    devices=/dev/kmsg:/dev/kmsg:rwm image=ghcr.io/home-assistant/home-assistant:stable \
    image_id=sha256:legacy ports='tcp 8123 python3 4242' "${@}"
  mk_legacy_unit
  set_http http://127.0.0.1:8123/manifest.json 200
}
# the woowtechopenclaw shape: podman-restart.service enabled, so at boot the user manager runs
# `podman start --all --filter restart-policy=always`
enable_restart_unit() {
  mkdir -p "$SHIM_STATE/units/podman-restart.service"
  echo enabled >"$SHIM_STATE/units/podman-restart.service/UnitFileState"
}
capture_dir() { printf '%s' "$1/legacy-container/homeassistant"; }

t_migrate_dry_run_derives_the_settings() {
  need_quadlet
  setup_legacy
  smoke_stub 0
  expect_ok "$R/scripts/migrate-legacy.sh" --dry-run
  has "$OUT" "HA_CONFIG_DIR=%h/ha-config"
  has "$OUT" "HA_PRIVILEGED=true"
  has "$OUT" "HA_ZIGBEE_DEVICE=/dev/kmsg"
  has "$OUT" "version gate"
  has "$OUT" "dry run complete"
  has "$(smoke_args)" "--legacy --snapshot"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "a dry run must install nothing"
  [[ -d $SHIM_STATE/containers/homeassistant ]] || die_t "a dry run must not rename anything"
  eq "$(ncalls 'podman stop')" 0 "a dry run must not stop anything"
}

t_migrate_refuses_a_bridge_network() {
  need_quadlet
  setup_legacy
  mk_container homeassistant "config_src=$CFG" network=bridge image_id=sha256:legacy
  expect_fail "$R/scripts/migrate-legacy.sh" --dry-run
  has "$OUT" "not host"
}

t_migrate_refuses_a_version_mismatch() {
  need_quadlet
  setup_legacy
  smoke_stub 0
  mk_image ghcr.io/home-assistant/home-assistant:stable 2026.8.0 sha256:legacy
  mk_image "$PIN_IMAGE" "$PIN_VER" sha256:pinned
  expect_fail "$R/scripts/migrate-legacy.sh" --dry-run
  has "$OUT" "pins $PIN_VER"
}

t_migrate_refuses_an_unmapped_mount() {
  need_quadlet
  setup_legacy
  mk_container homeassistant "config_src=$CFG" "mounts=/srv/media:/media" image_id=sha256:legacy
  expect_fail "$R/scripts/migrate-legacy.sh" --dry-run
  has "$OUT" "/srv/media -> /media"
}

t_migrate_then_rollback() {
  need_quadlet
  setup_legacy
  smoke_stub 0 0
  expect_ok "$R/scripts/migrate-legacy.sh" --yes
  has "$OUT" "Migration"
  # the legacy deployment is parked, the Quadlet one is installed
  local renamed
  renamed=$(basename "$(ls -d "$SHIM_STATE"/containers/homeassistant-legacy-*)")
  [[ -d $SHIM_STATE/containers/$renamed ]] || die_t "the legacy container was not renamed"
  eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["Config"]["Labels"].get("PODMAN_SYSTEMD_UNIT",""))' "$SHIM_STATE/containers/homeassistant/inspect.json")" \
    homeassistant.service "the container named homeassistant is now the Quadlet one"
  eq "$(cat "$SHIM_STATE/units/podman-ha.service/UnitFileState")" disabled "the legacy unit must be disabled"
  [[ -f $(SD)/podman-ha.service ]] || die_t "the legacy unit file must be kept"
  [[ -f $(Q)/homeassistant.container ]] || die_t "the Quadlet unit was not installed"
  grep -qx "Volume=${CFG/#"$HOME"/%h}:/config:rw" "$(Q)/homeassistant.container" || die_t "the config dir was not adopted"
  local B
  B=$(ls -d "$HOME"/backups/homeassistant/ha-pre-quadlet-*)
  [[ -f $B/backup/config.tgz && -f $B/preflight.json && -f $B/legacy/inspect.json ]] || die_t "the record is incomplete: $(ls -R "$B")"
  eq "$(sed -n 's/^STATUS=//p' "$B/migration.env")" "done" "recorded status"
  # rollback puts the legacy deployment back
  smoke_stub 0
  expect_ok "$R/scripts/migrate-legacy.sh" --rollback --yes
  [[ -d $SHIM_STATE/containers/homeassistant ]] || die_t "the legacy container was not renamed back"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "the Quadlet unit was not removed"
  eq "$(cat "$SHIM_STATE/units/podman-ha.service/UnitFileState")" enabled "the legacy unit must be enabled again"
  eq "$(cat "$SHIM_STATE/units/podman-ha.service/active")" active "the legacy unit must run again"
  eq "$(sed -n 's/^STATUS=//p' "$B/migration.env")" rolled-back "recorded status after the rollback"
}

# ---- the legacy rollback model: rename (toypark) vs capture (openclaw) ------------------------
t_migrate_keeps_the_rename_path_when_the_restart_unit_is_disabled() {
  need_quadlet
  setup_legacy restart=always # even an `always` container: nothing starts it at boot here
  smoke_stub 0 0
  expect_ok "$R/scripts/migrate-legacy.sh" --yes
  has "$OUT" "podman-restart.service is not enabled"
  local renamed B
  renamed=$(basename "$(ls -d "$SHIM_STATE"/containers/homeassistant-legacy-*)")
  [[ -d $SHIM_STATE/containers/$renamed ]] || die_t "the legacy container was not renamed"
  B=$(ls -d "$HOME"/backups/homeassistant/ha-pre-quadlet-*)
  eq "$(sed -n 's/^STRATEGY=//p' "$B/migration.env")" rename "recorded strategy"
  eq "$(sed -n 's/^RENAMED=//p' "$B/migration.env")" "$renamed" "recorded renamed container"
  [[ ! -e $(capture_dir "$B") ]] || die_t "the rename path must not write a capture"
  eq "$(ncalls 'podman commit')" 0 "the rename path must not commit"
  eq "$(ncalls 'podman rm homeassistant')" 0 "the rename path must not remove the legacy container"
}

t_migrate_captures_instead_of_renaming_when_the_restart_unit_would_revive_it() {
  need_quadlet
  setup_legacy restart=always
  enable_restart_unit
  smoke_stub 0 0
  expect_ok "$R/scripts/migrate-legacy.sh" --yes
  has "$OUT" "podman-restart.service is enabled"
  has "$OUT" "restart-policy=always"
  local B D
  B=$(ls -d "$HOME"/backups/homeassistant/ha-pre-quadlet-*)
  D=$(capture_dir "$B")
  eq "$(sed -n 's/^STRATEGY=//p' "$B/migration.env")" capture "recorded strategy"
  eq "$(sed -n 's/^RENAMED=//p' "$B/migration.env")" "" "nothing was renamed"
  ls -d "$SHIM_STATE"/containers/homeassistant-legacy-* >/dev/null 2>&1 \
    && die_t "the capture path must not leave a renamed copy that podman-restart would revive"
  for f in meta inspect.json createcommand.argv0 recreate.argv0 mounts NOTES.txt; do
    [[ -s $D/$f ]] || die_t "the capture is missing $f"
  done
  eq "$(sed -n 's/^RECREATABLE=//p' "$D/meta")" 1 "the capture is replayable"
  eq "$(sed -n 's/^RESTART_POLICY=//p' "$D/meta")" always "the policy is recorded"
  # --commit: HA pip-installs integration requirements into its own container, so the
  # writable layer has to survive the removal
  [[ -n $(sed -n 's/^COMMIT_IMAGE=//p' "$D/meta") ]] || die_t "the capture did not commit the writable layer"
  [[ $(ncalls 'podman commit') -ge 1 ]] || die_t "podman commit was never called"
  # the legacy container is gone, and it went with a plain rm: `rm -v` would delete the
  # anonymous volumes the capture expects to find again
  hasnt "$(calls)" "podman rm -v" "rm -v would delete the anonymous volumes"
  eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["Config"]["Labels"].get("PODMAN_SYSTEMD_UNIT",""))' "$SHIM_STATE/containers/homeassistant/inspect.json")" \
    homeassistant.service "the container named homeassistant is now the Quadlet one"
  eq "$(cat "$SHIM_STATE/units/podman-ha.service/UnitFileState")" disabled "the legacy unit must be disabled"
}

t_rollback_recreates_the_captured_container_with_its_policy() {
  need_quadlet
  setup_legacy restart=always
  enable_restart_unit
  smoke_stub 0 0
  expect_ok "$R/scripts/migrate-legacy.sh" --yes
  smoke_stub 0
  expect_ok "$R/scripts/migrate-legacy.sh" --rollback --yes
  has "$OUT" "recreated homeassistant"
  [[ -d $SHIM_STATE/containers/homeassistant ]] || die_t "the legacy container was not recreated"
  eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["HostConfig"]["RestartPolicy"]["Name"])' "$SHIM_STATE/containers/homeassistant/inspect.json")" \
    always "the original restart policy comes back; podman cannot change one afterwards"
  # it comes back from the committed image, so the pip-installed integration requirements
  # are there rather than being re-installed on the next start
  eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["ImageName"])' "$SHIM_STATE/containers/homeassistant/inspect.json" | cut -d/ -f1-2)" \
    localhost/woow-legacy "the recreate starts from the committed image"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "the Quadlet unit was not removed"
  eq "$(cat "$SHIM_STATE/units/podman-ha.service/UnitFileState")" enabled "the legacy unit must be enabled again"
  eq "$(cat "$SHIM_STATE/units/podman-ha.service/active")" active "the legacy unit must run again"
}

t_migrate_refuses_the_capture_path_for_an_api_created_container() {
  need_quadlet
  setup_legacy restart=always
  enable_restart_unit
  # a container created through the podman API (docker-compose over the socket, podman play)
  # records no CreateCommand, so there is nothing to replay and no way back
  python3 - "$SHIM_STATE/containers/homeassistant/inspect.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
d[0]["Config"]["CreateCommand"] = []
json.dump(d, open(sys.argv[1], "w"))
PY2
  expect_fail "$R/scripts/migrate-legacy.sh" --yes
  has "$OUT" "empty CreateCommand"
  [[ -d $SHIM_STATE/containers/homeassistant ]] || die_t "the legacy container must be untouched"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "nothing may be installed after the refusal"
  eq "$(ncalls 'podman rm homeassistant')" 0 "nothing was removed"
}

t_migrate_dry_run_reports_which_rollback_path_applies() {
  need_quadlet
  setup_legacy restart=always
  enable_restart_unit
  expect_ok "$R/scripts/migrate-legacy.sh" --dry-run
  has "$OUT" "capture homeassistant"
  [[ -d $SHIM_STATE/containers/homeassistant ]] || die_t "--dry-run must change nothing"
  eq "$(ncalls 'podman commit')" 0 "--dry-run must not commit"
}

t_migrate_rolls_back_when_the_post_check_fails() {
  need_quadlet
  setup_legacy
  smoke_stub 0 1 0
  expect_rc 1 "$R/scripts/migrate-legacy.sh" --yes
  has "$OUT" "rolling back automatically"
  [[ -d $SHIM_STATE/containers/homeassistant ]] || die_t "the legacy container was not renamed back"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "the Quadlet unit was not removed"
  eq "$(cat "$SHIM_STATE/units/podman-ha.service/active")" active "the legacy unit must run again"
}

t_migrate_keeps_the_deployment_with_no_auto_rollback() {
  need_quadlet
  setup_legacy
  smoke_stub 0 1
  expect_rc 1 "$R/scripts/migrate-legacy.sh" --yes --no-auto-rollback
  has "$OUT" "--rollback"
  [[ -f $(Q)/homeassistant.container ]] || die_t "the Quadlet unit must be kept for debugging"
}

t_migrate_aborts_and_restarts_the_legacy_when_the_port_stays_busy() {
  need_quadlet
  setup_legacy
  smoke_stub 0
  # a foreign process keeps 8123: the container stops but the port never frees
  cat >"$SHIM_STATE/ports.keep" <<'EOF'
tcp 8123 someone 999
EOF
  cp "$SHIM_STATE/ports.keep" "$SHIM_STATE/containers/homeassistant/ports"
  mkdir -p "$SHIM_STATE/containers/stuck"
  python3 -c 'import json,sys; json.dump([{"Name":"stuck","State":{"Running":True,"Status":"running"},"Config":{"Labels":{},"CreateCommand":[]},"HostConfig":{},"Mounts":[]}], open(sys.argv[1],"w"))' "$SHIM_STATE/containers/stuck/inspect.json"
  cp "$SHIM_STATE/ports.keep" "$SHIM_STATE/containers/stuck/ports"
  sync_ports
  expect_fail "$R/scripts/migrate-legacy.sh" --yes
  has "$OUT" "still in use"
  has "$OUT" "starting the legacy deployment again"
  [[ -d $SHIM_STATE/containers/homeassistant ]] || die_t "the legacy container must keep its name"
  [[ ! -e $(Q)/homeassistant.container ]] || die_t "nothing may be installed after the abort"
}

# ================================================================================================
# smoke.sh itself (with the real evaluator)
# ================================================================================================
t_smoke_snapshot_then_compare() {
  need_quadlet
  mk_repo
  mk_config_dir
  mk_env "HA_CONFIG_DIR=$CFG" HA_ZIGBEE_DEVICE=/dev/null HA_ZIGBEE_TARGET=/dev/null
  mk_container homeassistant label=homeassistant.service "config_src=$CFG" image="$PIN_IMAGE" \
    devices=/dev/null:/dev/null:rwm health=healthy ports='tcp 8123 python3 4242
tcp 21064 python3 4242
tcp 9584 python3 4242
udp 5353 python3 4242'
  mkdir -p "$(Q)" "$SHIM_STATE/units/homeassistant.service"
  sed "s|@@HA_CONFIG_DIR@@|$CFG|; s|@@HA_PORT@@|8123|; s|^@@HA_[A-Z_]*@@$||" \
    "$R/quadlet/homeassistant.container" >"$(Q)/homeassistant.container"
  echo active >"$SHIM_STATE/units/homeassistant.service/active"
  set_http http://127.0.0.1:8123/manifest.json 200
  set_http http://127.0.0.1:21064/ 401
  set_http http://127.0.0.1:9584/ 404
  expect_ok "$R/tests/smoke.sh" --snapshot "$T/pre.json"
  has "$OUT" "PASS  critical  http.local"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["storage"]["devices"]==2, d["storage"]; assert d["storage"]["zha_devices"]==1; assert d["storage"]["entities"]==3' "$T/pre.json" \
    || die_t "the snapshot does not hold the registry counts"
  # same state compares clean
  expect_ok "$R/tests/smoke.sh" --compare "$T/pre.json"
  # a ZHA device that disappeared is critical, and HomeKit going quiet too
  python3 - "$CFG/.storage/core.device_registry" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["data"]["devices"] = [x for x in d["data"]["devices"] if x["id"] != "d1"]
json.dump(d, open(p, "w"))
PY
  set_http http://127.0.0.1:21064/ 000
  expect_rc 1 "$R/tests/smoke.sh" --compare "$T/pre.json"
  has "$OUT" "FAIL  critical  compare.storage.zha_devices"
  has "$OUT" "FAIL  critical  compare.http_homekit"
}

# ================================================================================================
tests=$(declare -F | awk '{print $3}' | grep '^t_')
echo "scripts tests; podman shim + real Quadlet generator $(/usr/libexec/podman/quadlet -version 2>/dev/null || echo '(missing)')"
for t in $tests; do run "$t"; done
echo "----"
echo "passed: $npass  failed: $nfail  skipped: $nskip"
((nfail == 0)) || { echo "failed: ${FAILED[*]}"; exit 1; }
