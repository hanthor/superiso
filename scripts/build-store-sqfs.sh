#!/usr/bin/bash
# build-store-sqfs.sh <staging-dir> <output-sqfs>
#
# Builds the shared containers-storage squashfs.  At live-boot time, each
# live env's superiso-store.mount unit loop-mounts this file at
# /var/lib/containers/storage so every embedded image is available offline.
#
# Layout in the squashfs (root = /):
#   /  (== /var/lib/containers/storage at boot time)
#     overlay/             overlay-driver layer dirs (content-addressed)
#     overlay-images/      image manifests
#     overlay-layers/      layer metadata
#     overlay-containers/
#     storage.lock, userns.lock, images.{json,lock}, etc.

set -euo pipefail

STAGING="${1:?Usage: build-store-sqfs.sh <staging-dir> <output-sqfs>}"
OUT="${2:?Usage: build-store-sqfs.sh <staging-dir> <output-sqfs>}"

STORAGE="${STAGING}/var/lib/containers/storage"
[[ -d "${STORAGE}" ]] || { echo "ERROR: ${STORAGE} not present (run \`just stage\` first)" >&2; exit 1; }

case "${SUPERISO_COMPRESSION:-fast}" in
    release) SFS_LEVEL=15; SFS_BLOCK=1048576 ;;
    *)       SFS_LEVEL=3;  SFS_BLOCK=131072  ;;
esac

echo ">>> Building store squashfs from ${STORAGE} (level=${SFS_LEVEL}, block=${SFS_BLOCK})"
if [[ $(id -u) -eq 0 ]]; then
    du -sh "${STORAGE}" || true
else
    podman unshare du -sh "${STORAGE}" || du -sh "${STAGING}" || true
fi

if [[ $(id -u) -eq 0 ]]; then
    _ns() { bash -c "$1"; }
else
    _ns() { podman unshare bash -c "$1"; }
fi

# mksquashfs runs inside podman unshare so sub-uid mapped layer dirs are
# readable; mksquashfs records the canonical UIDs that match how the live
# kernel will see them (containers-storage inside the running ISO will be
# unshared-namespace-owned in the same way).
_ns "
    set -euo pipefail
    PATH=/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:\$PATH
    mksquashfs '${STORAGE}' '${OUT}' \\
        -noappend -comp zstd -Xcompression-level ${SFS_LEVEL} -b ${SFS_BLOCK} \\
        -processors 4
"

du -sh "${OUT}"
