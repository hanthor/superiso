#!/usr/bin/bash
# build-profile.sh <profile.json> [work-dir]
#
# One-config SuperISO build path:
#   profile.json -> generated installer/tacklebox artifacts -> live images -> ISO.

set -euo pipefail

PROFILE="${1:?Usage: build-profile.sh <profile.json> [work-dir]}"
WORK_DIR="${2:-}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$(realpath "$PROFILE")"
NAME="$(basename "$PROFILE" .json)"
NAME="${NAME%.profile}"

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="${SUPERISO_PROFILE_WORKDIR:-/var/tmp/superiso-profile-${NAME}}"
fi
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }
command -v podman >/dev/null || { echo "ERROR: podman required" >&2; exit 1; }

echo ">>> Generating profile artifacts: ${PROFILE}"
"${REPO}/scripts/gen-profile-artifacts.sh" "$PROFILE" "$WORK_DIR"

RECIPE="${WORK_DIR}/${NAME}.tacklebox.json"
MATRIX="${WORK_DIR}/${NAME}.live-build-matrix.json"
TBX="${SUPERISO_TACKLEBOX_BIN:-}"
if [[ -z "$TBX" ]]; then
    if command -v tacklebox >/dev/null 2>&1; then
        TBX="$(command -v tacklebox)"
    else
        echo ">>> Installing tacklebox binary from module path..."
        go install github.com/tuna-os/tacklebox/cmd/tacklebox@latest
        TBX="$(go env GOPATH)/bin/tacklebox"
    fi
fi

ISO="$(jq -r '.output_iso // empty' "$MATRIX")"
if [[ -z "$ISO" ]]; then
    ISO="${WORK_DIR}/${NAME}.iso"
fi
OUTPUT_BASE="$(jq -r '.output_base // empty' "$MATRIX")"
if [[ -z "$OUTPUT_BASE" ]]; then
    OUTPUT_BASE="${WORK_DIR}/.tbx-build"
fi
COMPRESSION="$(jq -r '.compression // "fast"' "$MATRIX")"
INSTALLER_CHANNEL="$(jq -r '.installer_channel // "stable"' "$MATRIX")"

mkdir -p "$(dirname "$ISO")" "$OUTPUT_BASE"

if [[ "${SUPERISO_GENERATE_ONLY:-0}" == "1" ]]; then
    echo ">>> Generate-only mode complete."
    echo "    Profile: $PROFILE"
    echo "    Work dir: $WORK_DIR"
    echo "    Tacklebox recipe: $RECIPE"
    echo "    Live build matrix: $MATRIX"
    echo "    ISO path: $ISO"
    exit 0
fi

echo ">>> Building tacklebox binary..."
(cd "${REPO}/tacklebox" && go build -o tacklebox ./cmd/tacklebox)

if [[ "${SUPERISO_SKIP_PULL:-0}" != "1" ]]; then
    echo ">>> Pre-pulling profile payload images..."
    PULL_TIMEOUT="${SUPERISO_PULL_TIMEOUT:-2400}"
    jq -r '.images[].ref' "$PROFILE" | while read -r ref; do
        [[ -n "$ref" ]] || continue
        if podman image exists "$ref"; then
            echo ">>> Already present: $ref"
        else
            echo ">>> Pulling: $ref (timeout=${PULL_TIMEOUT}s)"
            timeout "$PULL_TIMEOUT" podman pull --retry 5 --retry-delay 20s "$ref"
        fi
    done
else
    echo ">>> Skipping payload pulls (SUPERISO_SKIP_PULL=1)"
fi

echo ">>> Building transformed live images..."
jq -r '
  .live_environments[]
  | [
      .id,
      .family,
      (.desktop // ""),
      .base_image,
      .image
    ]
  | @tsv
' "$PROFILE" | while IFS=$'\t' read -r id family desktop base_image image; do
    if [[ "${SUPERISO_SKIP_LIVE_BUILD:-0}" == "1" ]] && podman image exists "$image"; then
        echo ">>> Skipping live build (already present): $image"
        continue
    fi

    echo ">>> Live image: id=${id} family=${family} base=${base_image} tag=${image}"
    podman build \
        --build-arg "BASE_IMAGE=${base_image}" \
        --build-arg "FAMILY=${family}" \
        --build-arg "DESKTOP=${desktop}" \
        --build-arg "INSTALLER_CHANNEL=${INSTALLER_CHANNEL}" \
        --tag "$image" \
        --file "${REPO}/live/Containerfile.generic" \
        "${REPO}/live"
done

echo ">>> Building ISO: $ISO"
SUPERISO_COMPRESSION="$COMPRESSION" \
TMPDIR="${TMPDIR:-/var/tmp}" \
"$TBX" build "$RECIPE" --iso "$ISO" -b "$OUTPUT_BASE"

echo ">>> Verifying ISO: $ISO"
"$TBX" verify "$ISO"

echo ">>> Profile build complete: $ISO"
