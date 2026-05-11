#!/usr/bin/bash
# profile-to-recipe.sh <profiles/*.tsv>
#
# Convert a SuperISO TSV profile into a tacklebox recipe JSON. Picks the
# rows where the `live` column is "true" — those become bootable
# environments. Non-live rows are payloads and aren't yet representable
# in tacklebox (see PLAN-merge.md §"Open questions": the
# extra-payloads/installer-source story needs a recipe-schema extension).
#
# Output: <repo-root>/recipes/<profile-basename>.json
#
# Sizing heuristic:
#   10 GiB per live env (one ublue ostree deployment + per-env kernel
#   headroom). bazzite has two live envs → 20 G, etc.

set -euo pipefail

TSV="${1:?Usage: profile-to-recipe.sh <profile.tsv>}"
[[ -f "$TSV" ]] || { echo "ERROR: $TSV not found" >&2; exit 1; }

name=$(basename "$TSV" .tsv)
mkdir -p "$(dirname "$0")/../recipes"
out="$(dirname "$0")/../recipes/${name}.json"

# Build the bootable_environments array from live rows. Each row:
#   col1 = image ref
#   col6 = family (becomes env id)
#   col7 = live flag (must be "true")
envs=$(awk -F'\t' '
    !/^#/ && NF >= 7 && $7 == "true" {
        printf "    {\"id\": \"%s\", \"image\": \"%s\", \"modes\": [\"live\"]}", $6, $1
        printf ",\n"
    }
' "$TSV" | sed '$s/,$//')

if [[ -z "$envs" ]]; then
    echo "ERROR: no live rows in $TSV" >&2
    exit 1
fi

# Count live envs to pick a sensible size.
n=$(awk -F'\t' '!/^#/ && NF >= 7 && $7 == "true"' "$TSV" | wc -l)
size_g=$(( n * 10 ))
[[ $size_g -lt 10 ]] && size_g=10

cat > "$out" <<EOF
{
  "media_name": "SuperISO-${name}",
  "size": "${size_g}G",
  "shared_store": {"format": "ext4"},
  "bootable_environments": [
${envs}
  ]
}
EOF

echo ">>> Wrote $out (${n} env(s), ${size_g}G)"
