#!/usr/bin/bash
# build-iso-tbx.sh <profile> <output-iso> [tacklebox-flags...]
#
# Build a SuperISO ISO via tacklebox (PLAN-merge step 6 — replaces the
# stack of scripts/build-{live-env,store-sqfs,iso}.sh with a single
# tacklebox invocation against recipes/<profile>.json).
#
# Examples:
#   scripts/build-iso-tbx.sh bluefin /var/mnt/data/out/bluefin.iso
#   scripts/build-iso-tbx.sh bazzite /var/mnt/data/out/bazzite.iso
#
# Profiles available: $(ls recipes/*.json | xargs -n1 basename -s .json)
#
# Differences vs the legacy build-iso.sh path:
#   - No separate live-env/store-sqfs build steps. tacklebox does the
#     container mount + mksquashfs + xorriso assembly in one pass.
#   - No additional offline image store yet — only the live row(s) of
#     each profile become bootable. The offline payload story (other
#     rows in profiles/*.tsv) needs a recipe-schema extension first
#     (see PLAN-merge.md §"Open questions").

set -euo pipefail

PROFILE="${1:?Usage: build-iso-tbx.sh <profile> <output-iso> [tacklebox-flags...]}"
OUT_ISO="${2:?Usage: build-iso-tbx.sh <profile> <output-iso> [tacklebox-flags...]}"
shift 2

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RECIPE="${REPO}/recipes/${PROFILE}.json"
TBX="${REPO}/tacklebox/tacklebox"

if [[ ! -f "$RECIPE" ]]; then
    echo "ERROR: recipe ${RECIPE} not found." >&2
    echo "Available profiles:" >&2
    ls "${REPO}/recipes/"*.json | xargs -n1 basename -s .json | sed 's/^/  /' >&2
    exit 1
fi

if [[ ! -x "$TBX" ]]; then
    echo ">>> tacklebox binary missing; building..."
    (cd "${REPO}/tacklebox" && go build -o tacklebox ./cmd/tacklebox)
fi

# tacklebox build needs sudo for losetup/mount/mkfs; --output-base lives
# next to the ISO so cleanup is easy.
OUTPUT_BASE="$(dirname "$OUT_ISO")/.tbx-build-${PROFILE}"
mkdir -p "$OUTPUT_BASE"

echo ">>> Building ${PROFILE} → ${OUT_ISO} via tacklebox"
sudo env "PATH=$PATH" "$TBX" build "$RECIPE" -b "$OUTPUT_BASE" --iso "$OUT_ISO" "$@"

echo ">>> Verifying ${OUT_ISO}"
"$TBX" verify "$OUT_ISO"
