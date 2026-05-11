#!/usr/bin/bash
# gen-images-json.sh <payloads.tsv> <output.json> [default-family]
#
# Renders the bootc-installer images.json schema from the TSV manifest.
# Every payload row (live or not) becomes an installer entry.  When a
# default-family is supplied (e.g. "bazzite" because we're rendering for
# the bazzite-nvidia live env), the installer pre-selects the *nvidia*
# variant of that family if present, otherwise the first matching row.

set -euo pipefail

TSV="${1:?Usage: gen-images-json.sh <payloads.tsv> <output.json> [default-family]}"
OUT="${2:?Usage: gen-images-json.sh <payloads.tsv> <output.json> [default-family]}"
DEFAULT_FAMILY="${3:-}"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

entries='[]'
default_ref=""
fallback_ref=""

while IFS=$'\t' read -r ref name desc fs cfs family live; do
    case "$ref" in ''|\#*) continue ;; esac
    [[ -z "$fallback_ref" ]] && fallback_ref="$ref"
    if [[ -n "$DEFAULT_FAMILY" && "$family" == "$DEFAULT_FAMILY" ]]; then
        # Prefer the live (nvidia) variant when available; otherwise first match.
        if [[ -z "$default_ref" || "$live" == "true" ]]; then
            default_ref="$ref"
        fi
    fi
    slug=$(printf '%s' "$ref" | sed -E 's|.*/([^/:]+).*|\1|; s|[^a-zA-Z0-9_-]|-|g')
    entry=$(jq -n \
        --arg name "$name" \
        --arg ref "$ref" \
        --arg desc "$desc" \
        --arg icon "/run/host/usr/share/bootc-installer/images/${slug}.svg" \
        --arg fs "$fs" \
        --argjson cfs "$cfs" \
        --arg family "$family" \
        '{name:$name, imgref:$ref, desc:$desc, icon:$icon,
          bootloader:"systemd", filesystem:$fs, composefs:$cfs,
          family:$family,
          needs_user_creation:true, flatpak_var_path:"state/os/default/var"}')
    entries=$(jq --argjson e "$entry" '. + [$e]' <<< "$entries")
done < "$TSV"

[[ -z "$default_ref" ]] && default_ref="$fallback_ref"

jq -n \
    --arg def "$default_ref" \
    --arg fam "$DEFAULT_FAMILY" \
    --argjson images "$entries" \
    '{default_image:$def, default_family:$fam, fallback_flatpaks:[], images:$images}' \
    > "$OUT"

echo ">>> Wrote $OUT (default=${default_ref}, family=${DEFAULT_FAMILY:-<none>}, $(jq '.images | length' "$OUT") images)"
