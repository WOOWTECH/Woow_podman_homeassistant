#!/usr/bin/env bash
# tests/smoke.sh: health and parity checks for the Home Assistant deployment. Read-only: it
# sends HTTP GETs (and one template POST), lists sockets, inspects the container and reads the
# config dir. Runs on the host after install, upgrade, migration and rollback.
#
#   tests/smoke.sh [--wait SECS] [--settle SECS] [--snapshot OUT.json] [--compare PRE.json]
#                  [--public-url URL] [--strict] [--legacy] [--env FILE]
#
#   --wait N        wait up to N s for HTTP 200, then keep re-checking until the critical checks
#                   pass (or N s are up)
#   --settle N      after the critical checks pass, keep re-checking degraded ones for up to N s
#                   (default 180) before reporting them
#   --snapshot F    save what was measured (JSON) for a later --compare
#   --compare F     also compare with a snapshot: registry counts, previously loaded config
#                   entries, entity availability, HomeKit/HA-MCP/mDNS/SSDP listeners, Matter,
#                   new ERROR signatures in home-assistant.log
#   --public-url U  also check U/manifest.json (200) and U/api/ (401; 400 = trusted_proxies broke)
#   --strict        every config entry that was loaded before is critical (default: zha, homekit)
#   --legacy        the container is not Quadlet-managed (pre-migration snapshot, after rollback)
#   --env FILE      settings file (default ~/.config/homeassistant/homeassistant.env)
#
# API checks need a long-lived token stored as a curl header file,
# ~/.config/homeassistant/smoke.header (0600): "Authorization: Bearer <token>". Without it the
# API checks are skipped and the report says so.
#
# Exit: 0 all passed, 1 a critical check failed, 2 only degraded checks failed.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
export QL_LOG_PREFIX=smoke

env_file=${HA_ENV_FILE:-$HOME/.config/homeassistant/homeassistant.env}
header=${HA_SMOKE_HEADER:-$HOME/.config/homeassistant/smoke.header}
qdir=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
poll=${HA_SMOKE_POLL:-15}
wait_s=0 settle=180 snapshot='' compare='' public='' strict=0 mode=quadlet
while (($#)); do
  case $1 in
    --wait) wait_s=${2:?--wait needs seconds}; shift ;;
    --settle) settle=${2:?--settle needs seconds}; shift ;;
    --snapshot) snapshot=${2:?--snapshot needs a file}; shift ;;
    --compare) compare=${2:?--compare needs a file}; shift ;;
    --public-url) public=${2:?--public-url needs a URL}; public=${public%/}; shift ;;
    --strict) strict=1 ;;
    --legacy) mode=legacy ;;
    --env) env_file=${2:?--env needs a file}; shift ;;
    -h | --help) sed -n '2,29p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ $wait_s =~ ^[0-9]+$ && $settle =~ ^[0-9]+$ ]] || ql_die "--wait and --settle take whole seconds"
command -v python3 >/dev/null 2>&1 || ql_die "python3 is required (sudo apt-get install python3)"
command -v ss >/dev/null 2>&1 || ql_die "ss is required (iproute2)"
[[ -z $compare || -r $compare ]] || ql_die "cannot read snapshot $compare"

ql_env_load "$env_file"
cfg=$(ql_expand_home "$(ql_env_get HA_CONFIG_DIR)")
port=$(ql_env_get HA_PORT 8123)
radio=''
[[ -z $(ql_env_get HA_ZIGBEE_DEVICE '') ]] || radio=$(ql_env_get HA_ZIGBEE_TARGET /dev/ttyACM0)
matter=0
[[ $(ql_env_get HA_MATTER false) == true ]] && matter=1
token=0
if [[ -r $header ]]; then
  token=1
  [[ $(stat -c %a -- "$header") =~ 00$ ]] || ql_warn "$header is readable by others; chmod 600 it"
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/ha-smoke.XXXXXX")
trap 'rm -rf "$W"' EXIT
F=$W/facts
EVAL=$REPO/tests/lib/smoke_eval.py
# One template call returns: states, unavailable states, zha entities, unavailable zha entities.
TEMPLATE=$(
  cat <<'EOF'
{"template":"{{ states|count }} {{ states|selectattr('state','eq','unavailable')|list|count }} {{ integration_entities('zha')|count }} {{ integration_entities('zha')|select('is_state','unavailable')|list|count }}"}
EOF
)

fact() { printf '%s=%s\n' "$1" "${2//$'\n'/ }" >>"$F"; }
code_of() {
  local c
  c=$(curl -s -o /dev/null -m "${2:-10}" -w '%{http_code}' "$1" 2>/dev/null) || true
  [[ $c =~ ^[0-9]{3}$ ]] || c=000
  printf '%s' "$c"
}
listening() { if [[ -n $(ss -Hln"$1" "sport = :$2" 2>/dev/null) ]]; then echo 1; else echo 0; fi; }
api_get() {
  local c
  c=$(curl -s -m 15 -H "@$header" -o "$W/$2" -w '%{http_code}' "http://127.0.0.1:$port$1" 2>/dev/null) || true
  [[ $c =~ ^[0-9]{3}$ ]] || c=000
  printf '%s' "$c"
}

gather() {
  : >"$F"
  rm -f "$W"/api_*
  fact mode "$mode"
  fact port "$port"
  fact http_local "$(code_of "http://127.0.0.1:$port/manifest.json")"
  fact tcp_ha "$(listening t "$port")"
  local p
  for p in 9584 21064 5580; do fact "tcp_$p" "$(listening t "$p")"; done
  for p in 5353 1900; do fact "udp_$p" "$(listening u "$p")"; done
  fact http_homekit "$(code_of http://127.0.0.1:21064/ 5)"
  fact http_hamcp "$(code_of http://127.0.0.1:9584/ 5)"
  fact http_matter "$(code_of http://127.0.0.1:5580/ 5)"
  fact mdns_hap "$(python3 "$REPO/tests/lib/mdns_query.py" _hap._tcp.local --timeout 3 2>/dev/null | awk '{print $1}' | sort -un | tr '\n' ' ')"
  fact matter_enabled "$matter"
  fact want_config_src "$(realpath -m -- "$cfg")"
  fact ha_version_file "$(cat -- "$cfg/.HA_VERSION" 2>/dev/null || true)"
  fact radio_dev "$radio"
  if [[ $mode == quadlet ]]; then
    fact unit_active "$(systemctl --user is-active homeassistant.service 2>/dev/null || true)"
    fact unit_nrestarts "$(systemctl --user show -p NRestarts --value homeassistant.service 2>/dev/null || true)"
    fact want_image "$(sed -n 's/^Image=//p' "$qdir/homeassistant.container" 2>/dev/null | tail -n1)"
  fi
  if podman container exists homeassistant >/dev/null 2>&1; then
    local info r l i s h src
    info=$(podman container inspect --format '{{.State.Running}}|{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}|{{.ImageName}}|{{.Config.StopTimeout}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' homeassistant 2>/dev/null) || info=''
    IFS='|' read -r r l i s h <<<"$info"
    [[ ${l:-} == '<no value>' ]] && l=''
    fact ctr_exists 1
    fact ctr_running "${r:-}"
    fact ctr_label "${l:-}"
    fact ctr_image "${i:-}"
    fact ctr_stop_timeout "${s:-}"
    fact ctr_health "${h:-}"
    src=$(podman container inspect --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' homeassistant 2>/dev/null) || src=''
    fact ctr_config_src "$src"
    if [[ -n $radio && ${r:-} == true ]]; then
      if podman exec homeassistant test -c "$radio" >/dev/null 2>&1; then fact radio_ok 1; else fact radio_ok 0; fi
    fi
  else
    fact ctr_exists 0
  fi
  fact token "$token"
  if ((token)); then
    fact api_config_code "$(api_get /api/config api_config.json)"
    fact api_entries_code "$(api_get /api/config/config_entries/entry api_entries.json)"
    printf '%s' "$TEMPLATE" >"$W/template.json"
    local c
    c=$(curl -s -m 20 -H "@$header" -H 'Content-Type: application/json' --data-binary "@$W/template.json" \
      -o "$W/api_template.txt" -w '%{http_code}' "http://127.0.0.1:$port/api/template" 2>/dev/null) || true
    [[ $c =~ ^[0-9]{3}$ ]] || c=000
    fact api_template_code "$c"
  fi
  if [[ -n $public ]]; then
    fact public_url "$public"
    fact public_manifest "$(code_of "$public/manifest.json" 20)"
    fact public_api "$(code_of "$public/api/" 20)"
  fi
}

eval_args=(--facts "$F" --work "$W" --config-dir "$cfg")
[[ -n $compare ]] && eval_args+=(--compare "$compare")
((strict)) && eval_args+=(--strict)
evaluate() { # evaluate [extra args]: prints the report, returns 0/1/2
  local rc=0
  python3 "$EVAL" "${eval_args[@]}" "$@" || rc=$?
  ((rc <= 2)) || { ql_warn "smoke_eval.py failed (rc=$rc)"; rc=1; }
  return "$rc"
}

deadline=$((SECONDS + wait_s))
if ((wait_s > 0)); then
  ql_wait_http "http://127.0.0.1:$port/manifest.json" 200 "$wait_s" || true
fi
if [[ -z $snapshot ]] && ((wait_s > 0)); then
  # Integrations keep loading after the first HTTP 200: re-check until the critical checks pass
  # (at most --wait), then give degraded ones up to --settle to recover.
  crit_ok_at=''
  while :; do
    gather
    rc=0
    evaluate --summary-only >"$W/summary" || rc=$?
    ((rc == 0 || SECONDS >= deadline)) && break
    if ((rc == 2)); then
      [[ -n $crit_ok_at ]] || crit_ok_at=$SECONDS
      ((SECONDS - crit_ok_at >= settle)) && break
    else
      crit_ok_at=''
    fi
    ql_info "not there yet: $(<"$W/summary")"
    sleep "$poll"
  done
else
  gather
fi
rc=0
if [[ -n $snapshot ]]; then
  evaluate --snapshot "$snapshot" || rc=$?
  ql_info "snapshot written to $snapshot"
else
  evaluate || rc=$?
fi
exit "$rc"
