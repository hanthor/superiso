#!/usr/bin/bash
# gen-recipe-json.sh <payloads.tsv> <output.json> <default-family>
# Generates a bootc-installer recipe matching the images embedded in this ISO.

set -euo pipefail

TSV="${1:?Usage: gen-recipe-json.sh <payloads.tsv> <output.json> <default-family>}"
OUT="${2:?Usage: gen-recipe-json.sh <payloads.tsv> <output.json> <default-family>}"
DEFAULT_FAMILY="${3:?Usage: gen-recipe-json.sh <payloads.tsv> <output.json> <default-family>}"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

profile="SuperISO"
profile_name=$(basename "$TSV")
case "$profile_name" in
    gold-*) profile="Gold SuperISO" ;;
esac
default_ref=""
default_composefs=true
fallback_ref=""
fallback_composefs=true
count=0

while IFS=$'\t' read -r ref name desc fs cfs family live; do
    case "$ref" in ''|\#*) continue ;; esac
    count=$((count + 1))
    if [[ -z "$fallback_ref" ]]; then
        fallback_ref="$ref"
        fallback_composefs="$cfs"
    fi
    if [[ "$family" == "$DEFAULT_FAMILY" ]]; then
        if [[ -z "$default_ref" || "$live" == "true" ]]; then
            default_ref="$ref"
            default_composefs="$cfs"
        fi
    fi
    case "$family" in
        *bazzite*) [[ "$profile" == "SuperISO" ]] && profile="Bazzite SuperISO" ;;
        *aurora*)  [[ "$profile" == "SuperISO" ]] && profile="Aurora SuperISO" ;;
        *bluefin*) [[ "$profile" == "SuperISO" ]] && profile="Bluefin SuperISO" ;;
        *dakota*)  [[ "$profile" == "SuperISO" ]] && profile="Dakota SuperISO" ;;
    esac
done < "$TSV"

if [[ -z "$default_ref" ]]; then
    default_ref="$fallback_ref"
    default_composefs="$fallback_composefs"
fi

default_slug=$(printf '%s' "$default_ref" | sed -E 's|.*/([^/:]+).*|\1|; s|[^a-zA-Z0-9_-]|-|g')
case "$profile_name" in
    gold-*|aurora*)
        logo="/run/host/usr/share/bootc-installer/images/superiso-logo.png"
        welcome="/run/host/usr/share/bootc-installer/images/superiso-welcome.png"
        ;;
    *)
        # Individual family ISOs use their default/live image branding.
        logo="/run/host/usr/share/bootc-installer/images/${default_slug}.svg"
        welcome="$logo"
        ;;
esac

jq -n \
  --arg distro "$profile" \
  --arg imgref "$default_ref" \
  --arg local "containers-storage:${default_ref}" \
  --arg count "$count" \
  --arg logo "$logo" \
  --arg welcome "$welcome" \
  --argjson compose "$default_composefs" \
  '{
    log_file:"/var/log/bootc-installer.log",
    distro_name:$distro,
    distro_logo:$logo,
    imgref:$imgref,
    local_imgref:$local,
    bootloader:"systemd",
    composeFsBackend:$compose,
    tour:{
      welcome:{
        image:$welcome,
        title:("Welcome to " + $distro),
        description:("This ISO contains " + $count + " deduped bootc images for offline installation.")
      },
      features:{
        image:$logo,
        title:"Offline by design",
        description:"Images are embedded in a shared overlay containers-storage store and mounted read-only as an additional image store."
      },
      community:{
        image:$logo,
        title:"Pick the image you want",
        description:"The image picker is generated from the profile manifest used to build this ISO."
      },
      developer:{
        image:$logo,
        title:"Deduped and flexible",
        description:"Profiles can build Dakota, Aurora, Bluefin, Bazzite, or a larger combined uBlue disk."
      },
      completed:{
        image:$logo,
        title:"Ready to install",
        description:"Choose a target disk and install without a network connection."
      }
    },
    steps:{
      welcome:{template:"welcome", protected:true},
      image:{template:"image", protected:true},
      disk:{template:"disk"},
      encryption:{template:"encryption"}
    }
  }' > "$OUT"

echo ">>> Wrote $OUT (profile=$profile, default=$default_ref, images=$count)"
