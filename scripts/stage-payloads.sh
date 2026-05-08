#!/usr/bin/bash
# stage-payloads.sh <payloads.tsv> <staging-dir> <live-image>
#
# Pulls every image listed in payloads.tsv into a single shared
# containers-storage at <staging-dir>/var/lib/containers/storage using the
# `overlay` driver.  Overlay (vs vfs) shares identical layer digests across
# images on disk — bazzite + bazzite-nvidia + bluefin all share the ublue
# base layers exactly once.  mksquashfs -dedup later catches near-identical
# blocks across non-shared layers.
#
# Why run skopeo *inside the live container image* (--rootfs):
#   The host build machine may ship a newer containers/storage that writes a
#   binary tar-split metadata format the live ISO's older containers/storage
#   cannot read.  The live image itself carries the version that will be
#   reading the storage at install time, so we let it write its own format.
#   (Same trick dakota-iso/justfile:251-257 uses for VFS.)
#
# Args:
#   payloads.tsv  TSV manifest (see scripts/gen-images-json.sh).
#   staging-dir   Directory that will become the squashfs containers-storage.
#   live-image    Local podman image of the live env (used to invoke skopeo
#                 with the runtime-matched containers/storage version).

set -euo pipefail

TSV="${1:?Usage: stage-payloads.sh <payloads.tsv> <staging-dir> <live-image>}"
STAGING="${2:?Usage: stage-payloads.sh <payloads.tsv> <staging-dir> <live-image>}"
LIVE_IMG="${3:?Usage: stage-payloads.sh <payloads.tsv> <staging-dir> <live-image>}"

STORAGE="${STAGING}/var/lib/containers/storage"
mkdir -p "${STORAGE}"

# Storage config used by skopeo inside the live container.  Paths are
# container-relative; /storage is bind-mounted to ${STORAGE}.
CONF=$(mktemp /tmp/superiso-storage-XXXXXX.conf)
trap "rm -f '${CONF}'" EXIT
cat > "${CONF}" <<EOF
[storage]
driver = "overlay"
runroot = "/tmp/cs-runroot"
graphroot = "/storage"
[storage.options.overlay]
mountopt = "nodev,metacopy=on"
EOF

# Some hosts don't allow nested overlay mounts inside an unprivileged podman
# container — fall back to the fuse-overlayfs driver if mount fails.  We try
# overlay first because it dedupes layers without per-file overhead.
run_skopeo_copy() {
    local ref="$1"
    podman run --rm \
        --privileged \
        --security-opt label=disable \
        -v "${STORAGE}:/storage" \
        -v "${CONF}:/tmp/st.conf:ro" \
        --entrypoint "" \
        "${LIVE_IMG}" \
        sh -c '
            mkdir -p /tmp/cs-runroot /var/tmp
            export CONTAINERS_STORAGE_CONF=/tmp/st.conf
            skopeo copy --quiet \
                "docker://'"$ref"'" \
                "containers-storage:'"$ref"'"
        '
}

while IFS=$'\t' read -r ref name desc fs cfs family live; do
    case "$ref" in ''|\#*) continue ;; esac
    echo ">>> Staging: ${ref}"
    run_skopeo_copy "$ref"
done < "${TSV}"

echo ">>> Staging size:"
du -sh "${STORAGE}"
echo ">>> Layer count:"
find "${STORAGE}/overlay" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l
