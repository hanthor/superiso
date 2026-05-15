#!/usr/bin/bash
# gen-profile-artifacts.sh <profile.json> [output-dir]
#
# Expands a single SuperISO profile into every derived build/input artifact:
# - normalized TSV manifest for the existing installer generators
# - tacklebox media recipe
# - per-live-family bootc-installer images.json and recipe.json
# - installer image assets
# - live image build matrix

set -euo pipefail

PROFILE="${1:?Usage: gen-profile-artifacts.sh <profile.json> [output-dir]}"
OUT_DIR="${2:-}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$(realpath "$PROFILE")"
NAME="$(basename "$PROFILE" .json)"
NAME="${NAME%.profile}"

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="${REPO}/output/profiles/${NAME}"
fi
OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }

jq -e '
  (.media_name | type == "string" and length > 0) and
  (.size | type == "string" and length > 0) and
  (.installer.channel | type == "string" and length > 0) and
  (.live_environments | type == "array" and length > 0) and
  (.images | type == "array" and length > 0)
' "$PROFILE" >/dev/null || {
    echo "ERROR: invalid profile schema: $PROFILE" >&2
    exit 1
}

mkdir -p \
    "$OUT_DIR" \
    "${REPO}/live/src/etc/bootc-installer" \
    "${REPO}/live/src/share/bootc-installer/images"

TSV="${OUT_DIR}/${NAME}.tsv"
RECIPE="${OUT_DIR}/${NAME}.tacklebox.json"
MATRIX="${OUT_DIR}/${NAME}.live-build-matrix.json"

jq -r '
  .images[]
  | [
      .ref,
      .name,
      .desc,
      .filesystem,
      (.composefs | tostring),
      .family,
      (.live | tostring)
    ]
  | @tsv
' "$PROFILE" > "$TSV"

jq '
  def default_boot_id:
    (.defaults.family // "") as $default_family
    | ([.live_environments[] | select(.family == $default_family) | .id][0] // .live_environments[0].id);

  {
    media_name,
    size,
    shared_store: {format: "ext4"},
    default_boot: default_boot_id,
    bootable_environments: [
      .live_environments[]
      | {
          id,
          image,
          desktop: (.desktop // ""),
          modes
        }
    ],
    offline_payloads: [.images[].ref]
  }
' "$PROFILE" > "$RECIPE"

jq '
  {
    installer_channel: .installer.channel,
    compression: (.compression // "fast"),
    output_iso: (.output_iso // ""),
    output_base: (.output_base // ""),
    live_environments
  }
' "$PROFILE" > "$MATRIX"

"${REPO}/scripts/gen-installer-assets.sh" "$TSV" "${REPO}/live/src/share/bootc-installer/images"

jq -r '.live_environments[].family' "$PROFILE" | while read -r family; do
    [[ -n "$family" ]] || continue
    "${REPO}/scripts/gen-images-json.sh" \
        "$TSV" \
        "${REPO}/live/src/etc/bootc-installer/images.${family}.json" \
        "$family"
    tmp="$(mktemp)"
    jq --slurpfile profile "$PROFILE" '
      ($profile[0].images | map({
        key:.ref,
        value:(
          {}
          + (if has("recommend_when") then {recommend_when} else {} end)
          + (if has("recommend_priority") then {recommend_priority} else {} end)
          + (if has("hardware_notes") then {hardware_notes} else {} end)
          + (if has("install_notes") then {install_notes} else {} end)
        )
      }) | from_entries) as $meta
      | .images = (.images | map(
          . as $img
          | if $meta[$img.imgref] then . + $meta[$img.imgref] else . end
        ))
    ' "${REPO}/live/src/etc/bootc-installer/images.${family}.json" > "$tmp"
    install -m 0644 "$tmp" "${REPO}/live/src/etc/bootc-installer/images.${family}.json"
    rm -f "$tmp"
    "${REPO}/scripts/gen-recipe-json.sh" \
        "$TSV" \
        "${REPO}/live/src/etc/bootc-installer/recipe.${family}.json" \
        "$family"
done

echo ">>> Wrote profile artifacts:"
echo "    TSV: $TSV"
echo "    Tacklebox recipe: $RECIPE"
echo "    Live build matrix: $MATRIX"
