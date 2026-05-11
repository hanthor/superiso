#!/usr/bin/bash
# gen-installer-assets.sh <payloads.tsv> <assets-dir>
# Creates simple SVG branding assets for every image slug plus generic SuperISO
# tour images.  These live on the host at /usr/share/bootc-installer/images and
# are referenced from the bootc-installer Flatpak via /run/host/...

set -euo pipefail

TSV="${1:?Usage: gen-installer-assets.sh <payloads.tsv> <assets-dir>}"
OUT="${2:?Usage: gen-installer-assets.sh <payloads.tsv> <assets-dir>}"
mkdir -p "$OUT"

mk_svg() {
    local file="$1" title="$2" subtitle="$3" color="$4"
    cat > "$file" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="96" fill="${color}"/>
  <circle cx="256" cy="184" r="92" fill="rgba(255,255,255,0.18)"/>
  <text x="256" y="178" text-anchor="middle" font-family="Cantarell, Inter, sans-serif" font-size="54" font-weight="800" fill="white">Super</text>
  <text x="256" y="238" text-anchor="middle" font-family="Cantarell, Inter, sans-serif" font-size="54" font-weight="800" fill="white">ISO</text>
  <text x="256" y="345" text-anchor="middle" font-family="Cantarell, Inter, sans-serif" font-size="38" font-weight="700" fill="white">${title}</text>
  <text x="256" y="392" text-anchor="middle" font-family="Cantarell, Inter, sans-serif" font-size="24" fill="rgba(255,255,255,0.82)">${subtitle}</text>
</svg>
EOF
}

color_for_family() {
    case "$1" in
        *bazzite*) echo '#7c3aed' ;;
        *aurora*)  echo '#0891b2' ;;
        *bluefin*) echo '#2563eb' ;;
        *dakota*)  echo '#16a34a' ;;
        *)         echo '#334155' ;;
    esac
}

mk_svg "$OUT/superiso.svg" "Offline" "bootc installer" '#334155'
mk_svg "$OUT/superiso-welcome.svg" "Welcome" "choose and install" '#0f172a'

# Project-provided logo from GitHub issue #2.  Use it only for Gold and Aurora
# profiles; Bluefin/Bazzite should keep their own/generated branding.
profile_name=$(basename "$TSV")
case "$profile_name" in
    gold-*|aurora*)
        if [[ -f live/src/branding/superiso-logo.png ]]; then
            cp live/src/branding/superiso-logo.png "$OUT/superiso-logo.png"
            cp live/src/branding/superiso-logo.png "$OUT/superiso-welcome.png"
        fi
        ;;
esac

while IFS=$'\t' read -r ref name desc fs cfs family live; do
    case "$ref" in ''|\#*) continue ;; esac
    slug=$(printf '%s' "$ref" | sed -E 's|.*/([^/:]+).*|\1|; s|[^a-zA-Z0-9_-]|-|g')
    color=$(color_for_family "$family")
    safe_name=$(printf '%s' "$name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    safe_family=$(printf '%s' "$family" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    mk_svg "$OUT/${slug}.svg" "$safe_name" "$safe_family" "$color"
done < "$TSV"

echo ">>> Wrote installer assets to $OUT"
