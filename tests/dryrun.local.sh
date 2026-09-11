# shellcheck shell=bash
# tests/dryrun.local.sh: Home Assistant checks on top of the vendored tests/dryrun.sh, which
# sources this file at the end. It can use run_variant, render_variant, $WORK, $REPO, $VARS,
# the base=() file list and the failures/variants counters defined there.
#
#  - optional-unit variants for each fixture (Matter; Matter + Postgres + backup timer)
#  - the generated ExecStart of homeassistant.service equals tests/golden/<fixture>.execstart,
#    which pins behaviour parity with the legacy `podman create` on toypark1234
#  - what the computed lines render to, per fixture
#  - bad env values make the render fail
# shellcheck disable=SC2154 # base, WORK, REPO, VARS come from tests/dryrun.sh

opt_matter=("$REPO"/quadlet/optional/homeassistant-matter.container "$REPO"/quadlet/optional/homeassistant-matter-data.volume)
run_variant fixture-toypark1234+matter "$REPO/tests/fixtures/toypark1234.env" "${base[@]}" "${opt_matter[@]}"
run_variant fixture-unprivileged-zigbee+optional "$REPO/tests/fixtures/unprivileged-zigbee.env" "${base[@]}" "$REPO"/quadlet/optional/*

# check <description> <command...>: one local assertion, counted like a variant
check() {
  local desc=$1
  shift
  variants=$((variants + 1))
  if "$@"; then
    echo "ok   check: $desc"
  else
    echo "FAIL check: $desc"
    failures=$((failures + 1))
  fi
}
has_line() { grep -qxF -- "$2" "$1"; }
no_line() { ! grep -qE -- "$2" "$1"; }

# execstart_of <rendered_dir> <unit>: ExecStart= of a generated unit
execstart_of() {
  QUADLET_UNIT_DIRS=$1 "$(_ql_quadlet_bin)" -dryrun -user 2>/dev/null \
    | awk -v u="---$2---" '$0 == u { on = 1; next } /^---.*---$/ { on = 0 } on && /^ExecStart=/ { sub(/^ExecStart=/, ""); print }'
}
golden_matches() {
  local name=$1 got want
  got=$(execstart_of "$WORK/fixture-$name/out" homeassistant.service)
  want=$(<"$REPO/tests/golden/$name.execstart")
  [[ $got == "$want" ]] && return 0
  printf '  want: %s\n  got:  %s\n' "$want" "$got" >&2
  return 1
}

echo "== golden ExecStart"
for g in "$REPO"/tests/golden/*.execstart; do
  n=$(basename "$g" .execstart)
  check "golden ExecStart for fixture $n" golden_matches "$n"
done

echo "== rendered values"
ex=$WORK/example+optional/out
tp=$WORK/fixture-toypark1234+matter/out
up=$WORK/fixture-unprivileged-zigbee+optional/out
check "example: default config dir" has_line "$ex/homeassistant.container" 'Volume=%h/homeassistant/config:/config:rw'
check "example: privileged" has_line "$ex/homeassistant.container" 'PodmanArgs=--privileged'
check "example: follows the host time zone" has_line "$ex/homeassistant.container" 'Timezone=local'
check "example: no devices" has_line "$ex/homeassistant.container" '# no devices passed (HA_ZIGBEE_DEVICE and HA_EXTRA_DEVICES are empty)'
check "example: Matter API on loopback" has_line "$ex/homeassistant-matter.container" 'Environment=LISTEN_ADDRESS=127.0.0.1'
check "example: Postgres on loopback 15432" has_line "$ex/homeassistant-db.container" 'PublishPort=127.0.0.1:15432:5432'
check "toypark: adopts ~/ha-config" has_line "$tp/homeassistant.container" 'Volume=%h/ha-config:/config:rw'
check "toypark: privileged" has_line "$tp/homeassistant.container" 'PodmanArgs=--privileged'
check "toypark: Zigbee by-id mapping" has_line "$tp/homeassistant.container" \
  'AddDevice=/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_20230803153503-if00:/dev/ttyACM0:rwm'
check "toypark: no Timezone= (UTC, as the legacy container)" no_line "$tp/homeassistant.container" '^Timezone='
check "toypark: no /run/dbus" no_line "$tp/homeassistant.container" '^Volume=/run/dbus'
check "unprivileged: keep-groups instead of --privileged" has_line "$up/homeassistant.container" 'PodmanArgs=--group-add=keep-groups'
check "unprivileged: no --privileged" no_line "$up/homeassistant.container" '^PodmanArgs=--privileged'
check "unprivileged: extra device" has_line "$up/homeassistant.container" 'AddDevice=/dev/ttyACM1:/dev/ttyACM1:rwm'
check "unprivileged: pinned time zone" has_line "$up/homeassistant.container" 'Timezone=Asia/Taipei'
check "unprivileged: BlueZ over /run/dbus" has_line "$up/homeassistant.container" 'Volume=/run/dbus:/run/dbus:ro'
check "unprivileged: Matter on every interface" no_line "$up/homeassistant-matter.container" '^Environment=LISTEN_ADDRESS='
check "unprivileged: Postgres port" has_line "$up/homeassistant-db.container" 'PublishPort=127.0.0.1:25432:5432'
check "ExecStartPre escapes \$ for systemd" grep -qF '[ $$i -ge 60 ]' "$tp/homeassistant.container"
check "backup timer runs the checkout via %h or a non-home path" \
  no_line "$ex/homeassistant-backup.service" "^ExecStart=.*${HOME}/"

echo "== bad values fail to render"
# bad_render <description> <KEY=VALUE>...: copy the toypark fixture, override keys, expect failure
bad_render() {
  local desc=$1 kv f=$WORK/bad.env
  shift
  cp "$REPO/tests/fixtures/toypark1234.env" "$f"
  for kv in "$@"; do
    grep -v "^${kv%%=*}=" "$f" >"$f.tmp" || true
    printf '%s\n' "$kv" >>"$f.tmp"
    mv -f "$f.tmp" "$f"
  done
  rm -rf "$WORK/bad"
  mkdir -p "$WORK/bad/src" "$WORK/bad/out"
  cp -p "${base[@]}" "$WORK/bad/src/"
  if (render_variant "$WORK/bad/src" "$f" "$WORK/bad/out") >/dev/null 2>&1; then
    echo "  rendered although $* is invalid" >&2
    return 1
  fi
  return 0
}
check "rejects HA_PRIVILEGED=yes" bad_render privileged HA_PRIVILEGED=yes
check "rejects a ':' in HA_CONFIG_DIR" bad_render config HA_CONFIG_DIR=%h/ha:config
check "rejects a relative HA_CONFIG_DIR" bad_render config HA_CONFIG_DIR=ha-config
check "rejects a non-/dev Zigbee device" bad_render device HA_ZIGBEE_DEVICE=ttyACM0
check "rejects a malformed extra device" bad_render extra 'HA_EXTRA_DEVICES=/dev/ttyACM1:/dev/ttyACM1:xyz'
check "rejects HA_BLUETOOTH=1" bad_render bluetooth HA_BLUETOOTH=1
check "rejects a time zone with spaces" bad_render tz 'HA_TZ=Asia Taipei'
check "rejects a non-numeric HA_PORT" bad_render port HA_PORT=http
