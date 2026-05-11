#!/usr/bin/bash
# check-profile-refs.sh <profile.tsv> [max-age-days]
# Verifies that every manifest ref exists and is not older than max-age-days.
# Also enforces Gold policy: no Bluefin/Aurora GTS and no bluefin :latest refs.

set -euo pipefail

TSV="${1:?Usage: check-profile-refs.sh <profile.tsv> [max-age-days]}"
MAX_AGE="${2:-90}"
NOW_EPOCH="${SUPERISO_NOW_EPOCH:-$(date -u +%s)}"

fail=0

while IFS=$'\t' read -r ref name desc fs cfs family live; do
    case "$ref" in ''|\#*) continue ;; esac

    if [[ "$ref" =~ ghcr\.io/ublue-os/(bluefin|aurora).*:gts ]]; then
        echo "DEAD-POLICY gts excluded: $ref" >&2
        fail=1
        continue
    fi
    if [[ "$ref" =~ ghcr\.io/ublue-os/bluefin.*:latest ]]; then
        echo "DEAD-POLICY bluefin :latest excluded: $ref" >&2
        fail=1
        continue
    fi

    inspect=$(skopeo inspect --no-tags "docker://${ref}" 2>/dev/null) || {
        echo "MISSING $ref" >&2
        fail=1
        continue
    }
    created=$(jq -r '.Created // empty' <<< "$inspect")
    if [[ -z "$created" ]]; then
        echo "UNKNOWN-AGE $ref"
        continue
    fi
    created_epoch=$(date -u -d "$created" +%s 2>/dev/null || true)
    if [[ -z "$created_epoch" ]]; then
        echo "BAD-DATE $created $ref" >&2
        fail=1
        continue
    fi
    age_days=$(( (NOW_EPOCH - created_epoch) / 86400 ))
    if (( age_days > MAX_AGE )); then
        echo "OLD ${age_days}d $created $ref" >&2
        fail=1
    else
        echo "OK ${age_days}d $created $ref"
    fi
done < "$TSV"

exit "$fail"
