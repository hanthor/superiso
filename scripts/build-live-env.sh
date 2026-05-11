#!/usr/bin/bash
# build-live-env.sh <payloads.tsv> <family> <ref> <output-dir>
#
# Build artefacts for ONE live env (one bootable family on the super-ISO):
#
#   <output-dir>/live/<family>/vmlinuz             kernel
#   <output-dir>/live/<family>/initramfs.img       dmsquash-live initramfs
#   <output-dir>/live/<family>/EFI                 systemd-boot EFI binaries (per-arch)
#   <output-dir>/live/<family>/rootfs.sfs          rootfs squashfs (no embedded store)
#
# How it works:
#   1. Render images.<family>.json with default_family pre-selected.
#   2. Build localhost/superiso-live-<family> via the distro-agnostic live Containerfile.
#   3. podman image mount → cp -a into a staging tree.
#   4. Strip /var/lib/containers/storage from the staging tree (the store is
#      shared across all live envs and lives in its own squashfs).
#   5. mksquashfs the staging tree.
#   6. Extract kernel + initramfs + EFI binaries into output/live/<family>/.

set -euo pipefail

TSV="${1:?Usage: build-live-env.sh <payloads.tsv> <family> <ref> <output-dir>}"
FAMILY="${2:?...}"
REF="${3:?...}"
OUT="${4:?...}"

# Default to the distro-agnostic live transform.  It builds dmsquash-live in a
# Debian helper stage and does not use the base image's package manager or
# Fedora livesys scripts.  Override only for debugging:
#   SUPERISO_LIVE_CONTAINERFILE=live/Containerfile.ublue
CF="${SUPERISO_LIVE_CONTAINERFILE:-live/Containerfile.generic}"

# Compression preset (override via SUPERISO_COMPRESSION env: "fast" | "release")
case "${SUPERISO_COMPRESSION:-fast}" in
    release) SFS_LEVEL=15; SFS_BLOCK=1048576 ;;
    *)       SFS_LEVEL=3;  SFS_BLOCK=131072  ;;
esac

LIVE_OUT="${OUT}/live/${FAMILY}"
BUILD_TMP="${SUPERISO_BUILD_TMPDIR:-${OUT}/tmp}"
mkdir -p "${LIVE_OUT}" "${BUILD_TMP}"

# ── 1. Render per-family images.json ────────────────────────────────────────
mkdir -p live/src/etc/bootc-installer
bash scripts/gen-images-json.sh "${TSV}" \
    "live/src/etc/bootc-installer/images.${FAMILY}.json" \
    "${FAMILY}"
bash scripts/gen-recipe-json.sh "${TSV}" \
    "live/src/etc/bootc-installer/recipe.${FAMILY}.json" \
    "${FAMILY}"
bash scripts/gen-installer-assets.sh "${TSV}" \
    "live/src/share/bootc-installer/images"

# ── 2. Build the live-env container image ───────────────────────────────────
# Persistence is scoped by desktop environment, not distro/family.  Infer the
# live desktop from the selected live row.  Override with SUPERISO_DESKTOP if
# a future profile needs an explicit value.
row=$(awk -F'\t' -v ref="${REF}" -v fam="${FAMILY}" 'BEGIN{IGNORECASE=1} $1==ref && $6==fam {print $0; exit}' "${TSV}")
DESKTOP="${SUPERISO_DESKTOP:-}"
if [[ -z "${DESKTOP}" ]]; then
    if grep -Eiq 'aurora|kde|plasma' <<< "${row}"; then
        DESKTOP=kde
    else
        DESKTOP=gnome
    fi
fi

LIVE_IMG="localhost/superiso-live-${FAMILY}"
echo ">>> [${FAMILY}] Building ${LIVE_IMG} from ${REF} (desktop=${DESKTOP})"
TMPDIR="${BUILD_TMP}" podman build \
    --build-arg "BASE_IMAGE=${REF}" \
    --build-arg "FAMILY=${FAMILY}" \
    --build-arg "DESKTOP=${DESKTOP}" \
    -t "${LIVE_IMG}" \
    -f "${CF}" \
    live

# ── 3-6. Mount, strip store, squashfs, extract boot files ───────────────────
if [[ $(id -u) -eq 0 ]]; then
    _ns() { bash -c "$1"; }
else
    _ns() { podman unshare bash -c "$1"; }
fi

_ns "
    set -euo pipefail
    LIVE_IMG='${LIVE_IMG}'
    LIVE_OUT='${LIVE_OUT}'
    BUILD_TMP='${BUILD_TMP}'
    SFS_LEVEL='${SFS_LEVEL}'
    SFS_BLOCK='${SFS_BLOCK}'

    SROOT=\$(mktemp -d "\${BUILD_TMP}/superiso-${FAMILY}-root.XXXXXX")
    OVERLAY_UPPER=\$(mktemp -d "\${BUILD_TMP}/superiso-${FAMILY}-upper.XXXXXX")
    OVERLAY_WORK=\$(mktemp -d "\${BUILD_TMP}/superiso-${FAMILY}-work.XXXXXX")

    cleanup() {
        umount \"\${SROOT}\" 2>/dev/null || true
        podman image unmount \"\${LIVE_IMG}\" 2>/dev/null || true
        rm -rf \"\${OVERLAY_UPPER}\" \"\${OVERLAY_WORK}\" \"\${SROOT}\" 2>/dev/null || true
    }
    trap cleanup EXIT

    MOUNT=\$(podman image mount \"\${LIVE_IMG}\")
    PATH=/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:\$PATH

    # Overlay the image rootfs — shared store directory is stripped via upperdir.
    FS_TYPE=\$(findmnt -n -o FSTYPE -T /var/tmp 2>/dev/null || echo unknown)
    if [[ \"\${FS_TYPE}\" == xfs || \"\${FS_TYPE}\" == ext4 ]] \\
        && mount -t overlay overlay \\
            -o lowerdir=\"\${MOUNT}\",upperdir=\"\${OVERLAY_UPPER}\",workdir=\"\${OVERLAY_WORK}\" \\
            \"\${SROOT}\"; then
        echo \">>> overlay mounted (\${FS_TYPE})\"
    else
        echo \">>> overlay unsupported on \${FS_TYPE}; falling back to cp -a\"
        cp -a \"\${MOUNT}/.\" \"\${SROOT}/\"
    fi

    # Strip the per-image containers-storage tree — it's redundant with the
    # shared store squashfs and bloats the rootfs squashfs by ~6 GB.
    rm -rf \"\${SROOT}/var/lib/containers/storage\"
    mkdir -p \"\${SROOT}/var/lib/containers/storage\"

    # Build rootfs squashfs.
    echo \">>> [${FAMILY}] mksquashfs (level=\${SFS_LEVEL}, block=\${SFS_BLOCK})\"
    mksquashfs \"\${SROOT}\" \"\${LIVE_OUT}/rootfs.sfs\" \\
        -noappend -comp zstd -Xcompression-level \${SFS_LEVEL} -b \${SFS_BLOCK} \\
        -processors 4 \\
        -e proc -e sys -e dev -e run -e tmp

    # Extract boot files for ESP assembly.
    kver=\$(find "\${MOUNT}/usr/lib/modules" -maxdepth 2 -name "modules.dep" -print | head -1 | xargs dirname | xargs basename)
    cp "\${MOUNT}/usr/lib/modules/\${kver}/vmlinuz"      "\${LIVE_OUT}/vmlinuz"
    cp "\${MOUNT}/usr/lib/modules/\${kver}/initramfs.img" "\${LIVE_OUT}/initramfs.img"
    mkdir -p \"\${LIVE_OUT}/EFI\"
    if [[ -d \"\${MOUNT}/usr/lib/systemd/boot/efi\" ]]; then
        cp -r \"\${MOUNT}/usr/lib/systemd/boot/efi/.\" \"\${LIVE_OUT}/EFI/\"
    else
        echo \">>> [${FAMILY}] no systemd-boot EFI binaries (image uses GRUB?) — skipping; another family must supply them\"
    fi

    echo \">>> [${FAMILY}] kernel=\${kver}\"
    du -sh \"\${LIVE_OUT}/rootfs.sfs\" \"\${LIVE_OUT}/vmlinuz\" \"\${LIVE_OUT}/initramfs.img\"
"
