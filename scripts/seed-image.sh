#!/usr/bin/env bash
# Copy a preinstall image's reviewed /config payload into a host config directory.
# Official HA images carry no io.woowtech.preinstall label and are skipped.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
image=${1:?usage: seed-image.sh IMAGE CONFIG_DIR STATE_FILE}
target=${2:?usage: seed-image.sh IMAGE CONFIG_DIR STATE_FILE}
state=${3:?usage: seed-image.sh IMAGE CONFIG_DIR STATE_FILE}

label=$(
  podman image inspect "$image" |
    python3 -c 'import json,sys; x=json.load(sys.stdin)[0]; print((x.get("Labels") or x.get("Config",{}).get("Labels") or x.get("labels") or {}).get("io.woowtech.preinstall", ""))'
)
if [[ $label != 1 ]]; then
  printf 'seed: image %s has no preinstall payload\n' "$image"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/ha-image-seed.XXXXXX")
cid=''
cleanup() {
  [[ -z $cid ]] || podman rm -f "$cid" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT
cid=$(podman create --pull=never --entrypoint /bin/true "$image")
podman cp "$cid:/config/." "$work/"
python3 "$REPO/scripts/seed-config.py" --source "$work" --target "$target" --state "$state" --image "$image"
