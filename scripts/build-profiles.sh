#!/usr/bin/bash
# Build multiple Super-ISO profiles concurrently.
#
# Usage:
#   scripts/build-profiles.sh [profile ...]
#
# Defaults to: dakota aurora bluefin bazzite
# Each profile uses profiles/<name>.tsv and output/<name>/ so builds can run
# independently.  Logs go to output/logs/<profile>.log.

set -euo pipefail

COMPRESSION="${SUPERISO_COMPRESSION:-${compression:-fast}}"
JOBS="${SUPERISO_PROFILE_JOBS:-4}"
OUTPUT_BASE="${SUPERISO_OUTPUT_BASE:-output}"
PROFILES=("${@:-dakota aurora bluefin bazzite}")

if [[ "$#" -eq 0 ]]; then
    PROFILES=(dakota aurora bluefin bazzite)
fi

mkdir -p "${OUTPUT_BASE}/logs"

running=0
pids=()
names=()

wait_one() {
    local pid name rc
    pid="${pids[0]}"
    name="${names[0]}"
    if wait "$pid"; then
        echo ">>> [${name}] complete"
    else
        rc=$?
        echo ">>> [${name}] FAILED (see ${OUTPUT_BASE}/logs/${name}.log)" >&2
        return "$rc"
    fi
    pids=("${pids[@]:1}")
    names=("${names[@]:1}")
    running=$((running - 1))
}

for profile in "${PROFILES[@]}"; do
    manifest="profiles/${profile}.tsv"
    [[ -f "$manifest" ]] || { echo "ERROR: missing $manifest" >&2; exit 1; }

    while (( running >= JOBS )); do
        wait_one
    done

    log="${OUTPUT_BASE}/logs/${profile}.log"
    echo ">>> [${profile}] starting: payloads=${manifest} output_dir=${OUTPUT_BASE}/${profile} compression=${COMPRESSION}"
    (
        set -euo pipefail
        just \
            payloads="${manifest}" \
            output_dir="${OUTPUT_BASE}/${profile}" \
            compression="${COMPRESSION}" \
            all
    ) >"$log" 2>&1 &

    pids+=("$!")
    names+=("$profile")
    running=$((running + 1))
done

while (( running > 0 )); do
    wait_one
done

echo ">>> All requested profiles complete."
