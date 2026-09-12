# shellcheck shell=bash
# scripts/render-args.sh: values computed from the env file. Sourced by scripts/install.sh,
# scripts/migrate-legacy.sh and tests/dryrun.sh, so CI renders exactly what a host gets.
#
# render_args <envfile>: QL_ENV is loaded (ql_env_load); sets RENDER_ARGS=(KEY=VALUE...).
# It validates the syntax of every value it uses and dies (ql_assert_match) on a bad one.
# It never looks at the host: device existence and the privileged/by-id rule are checked by
# scripts/install.sh. Every computed value is one or more whole unit-file lines; a feature
# that is off renders as a comment, so the installed unit says what was chosen.

render_args() {
  local priv dev tgt extra tz bt listen cfg port dbport repo home_p spec lines=''
  local -a q_extra=()

  cfg=$(ql_env_get HA_CONFIG_DIR)
  ql_assert_match HA_CONFIG_DIR "$cfg" '(%h/|/)[^:[:space:]]*'
  port=$(ql_env_get HA_PORT 8123)
  ql_assert_match HA_PORT "$port" '[1-9][0-9]{0,4}'
  dbport=$(ql_env_get HA_DB_PORT 15432)
  ql_assert_match HA_DB_PORT "$dbport" '[1-9][0-9]{0,4}'

  # --privileged, or only the listed devices plus the user's supplementary groups (dialout).
  # GroupAdd= is not a podman 4.9.3 Quadlet key, hence PodmanArgs.
  priv=$(ql_env_get HA_PRIVILEGED true)
  ql_assert_match HA_PRIVILEGED "$priv" 'true|false'
  local priv_line='PodmanArgs=--group-add=keep-groups'
  [[ $priv == true ]] && priv_line='PodmanArgs=--privileged'

  dev=$(ql_env_get HA_ZIGBEE_DEVICE '')
  tgt=$(ql_env_get HA_ZIGBEE_TARGET /dev/ttyACM0)
  extra=$(ql_env_get HA_EXTRA_DEVICES '')
  [[ -z $dev ]] || ql_assert_match HA_ZIGBEE_DEVICE "$dev" '/dev/[^:[:space:]]+'
  ql_assert_match HA_ZIGBEE_TARGET "$tgt" '/dev/[^:[:space:]]+'
  read -ra q_extra <<<"$extra"
  if [[ $priv == true && ( -n $dev || ${#q_extra[@]} -gt 0 ) ]]; then
    # F2 in the plan: rootless podman 4.9.3 drops --device when --privileged is set.
    lines='# AddDevice= has no effect while --privileged is set: HA sees the host node names,'$'\n'
    lines+='# so install.sh checks that each by-id link resolves to its container path.'$'\n'
  fi
  [[ -z $dev ]] || lines+="AddDevice=$dev:$tgt:rwm"$'\n'
  for spec in "${q_extra[@]}"; do
    ql_assert_match "HA_EXTRA_DEVICES entry" "$spec" '/dev/[^:[:space:]]+(:/[^:[:space:]]+(:[rwm]{1,3})?)?'
    lines+="AddDevice=$spec"$'\n'
  done
  lines=${lines%$'\n'}
  [[ -n $lines ]] || lines='# no devices passed (HA_ZIGBEE_DEVICE and HA_EXTRA_DEVICES are empty)'

  tz=$(ql_env_get HA_TZ '')
  local tz_line='# no Timezone=: the container runs in UTC (HA_TZ is empty)'
  if [[ -n $tz ]]; then
    ql_assert_match HA_TZ "$tz" 'local|[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*'
    tz_line="Timezone=$tz"
  fi

  bt=$(ql_env_get HA_BLUETOOTH false)
  ql_assert_match HA_BLUETOOTH "$bt" 'true|false'
  local dbus_line='# no /run/dbus mount (HA_BLUETOOTH=false)'
  [[ $bt == true ]] && dbus_line='Volume=/run/dbus:/run/dbus:ro'

  listen=$(ql_env_get HA_MATTER_LISTEN_ADDRESS 127.0.0.1)
  local listen_line='# LISTEN_ADDRESS is not set: the Matter WebSocket API listens on every interface'
  if [[ -n $listen ]]; then
    ql_assert_match HA_MATTER_LISTEN_ADDRESS "$listen" '[A-Za-z0-9.:_-]+'
    listen_line="Environment=LISTEN_ADDRESS=$listen"
  fi

  # The checkout the backup timer runs scripts/backup.sh from, as %h/... when under $HOME.
  repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  home_p=$(cd "$HOME" 2>/dev/null && pwd -P) || home_p=$HOME
  case $repo in
    "$HOME"/*) repo="%h/${repo#"$HOME"/}" ;;
    "$home_p"/*) repo="%h/${repo#"$home_p"/}" ;;
  esac
  ql_assert_match "repo checkout path (move the checkout to a path without spaces or special characters)" \
    "$repo" '(%h/)?[A-Za-z0-9._/+-]+'

  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller
  RENDER_ARGS=(
    "HA_PRIVILEGE_LINE=$priv_line"
    "HA_DEVICE_LINES=$lines"
    "HA_TZ_LINE=$tz_line"
    "HA_DBUS_LINE=$dbus_line"
    "HA_MATTER_LISTEN_LINE=$listen_line"
    "HA_REPO_DIR=$repo"
  )
}
