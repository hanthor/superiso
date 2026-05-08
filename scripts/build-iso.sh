#!/usr/bin/bash
# build-iso.sh <output-dir> <output-iso>
#
# Multi-boot super-ISO assembly.  Reads <output-dir>/live/<family>/{vmlinuz,
# initramfs.img,rootfs.sfs,EFI} produced by build-live-env.sh, and the shared
# <output-dir>/store.sfs produced by build-store-sqfs.sh.  Emits a single
# UEFI-bootable ISO (label SUPERISO) with one systemd-boot menu entry per
# family.
#
# Layout in the ISO:
#
#   /EFI/efi.img                   FAT ESP — systemd-boot + per-family kernels
#       /loader/loader.conf
#       /loader/entries/<family>.conf
#       /images/pxeboot/<family>/{vmlinuz,initrd.img}
#       /EFI/BOOT/BOOTX64.EFI      systemd-boot binary (per-arch)
#   /EFI/BOOT/BOOTX64.EFI          fallback path on the ISO9660 root for
#                                   firmware that doesn't read El Torito
#   /images/pxeboot/<family>/{vmlinuz,initrd.img}    loopback boot copies
#   /LiveOS/<family>.rootfs.sfs    per-family rootfs squashfs
#   /LiveOS/store.squashfs.img     shared containers-storage squashfs
#   /boot/grub/loopback.cfg        Ventoy/GRUB loopback metadata
#
# Kernel cmdline (per family):
#   root=live:CDLABEL=SUPERISO
#   rd.live.image rd.live.dir=LiveOS
#   rd.live.squashimg=<family>.rootfs.sfs
#   rd.live.overlay=LABEL=SUPERISOPST   # optional persistent overlay
#   rd.live.overlay.overlayfs=1
#   superiso.family=<family>
#
# The shared store at /LiveOS/store.squashfs.img is loop-mounted at
# /var/lib/containers/storage by superiso-store.mount inside the booted env.

set -euo pipefail

OUT="${1:?Usage: build-iso.sh <output-dir> <output-iso>}"
OUTPUT_ISO="${2:?Usage: build-iso.sh <output-dir> <output-iso>}"
LABEL="SUPERISO"
PERSIST_LABEL="SUPERISOPST"

[[ -d "${OUT}/live" ]] || { echo "ERROR: ${OUT}/live missing — run build-live-env.sh first" >&2; exit 1; }
[[ -f "${OUT}/store.sfs" ]] || { echo "ERROR: ${OUT}/store.sfs missing — run build-store-sqfs.sh first" >&2; exit 1; }

mapfile -t FAMILIES < <(ls "${OUT}/live" | sort)
[[ "${#FAMILIES[@]}" -gt 0 ]] || { echo "ERROR: no families under ${OUT}/live" >&2; exit 1; }

echo ">>> Families: ${FAMILIES[*]}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/iso-build.XXXXXX")
trap "chmod -R u+rwX '${WORK}' 2>/dev/null; rm -rf '${WORK}'" EXIT
ISO_ROOT="${WORK}/iso-root"
ESP_STAGING="${WORK}/esp-staging"

mkdir -p "${ISO_ROOT}/EFI" "${ISO_ROOT}/LiveOS" "${ISO_ROOT}/images/pxeboot" "${ISO_ROOT}/boot/grub"
mkdir -p "${ESP_STAGING}/EFI/BOOT" "${ESP_STAGING}/loader/entries" "${ESP_STAGING}/images/pxeboot"

# ── EFI binary (pick whichever family ships systemd-boot — e.g. dakota) ─────
EFI_SRC=""
EFI_DEST=""
for fam in "${FAMILIES[@]}"; do
    for cand in \
        "systemd-bootaa64.efi:EFI/BOOT/BOOTAA64.EFI" \
        "systemd-bootx64.efi:EFI/BOOT/BOOTX64.EFI"; do
        f="${OUT}/live/${fam}/EFI/${cand%%:*}"
        if [[ -f "$f" ]]; then
            EFI_SRC="$f"
            EFI_DEST="${cand##*:}"
            echo ">>> EFI binary sourced from family: ${fam}"
            break 2
        fi
    done
done
[[ -n "${EFI_SRC}" ]] || { echo "ERROR: no systemd-boot EFI binary found in any family"; exit 1; }
cp "${EFI_SRC}" "${ESP_STAGING}/${EFI_DEST}"

# ── Loader config + per-family entries + per-family kernel/initramfs ────────
DEFAULT_FAMILY="${FAMILIES[0]}"
# Prefer bluefin/aurora/bazzite as default (ublue images with reliable
# dnf-built dmsquash-live initramfs).  Dakota live builds are out of MVP
# scope (GNOME OS / no dnf).
for d in bluefin aurora bazzite dakota; do
    [[ -d "${OUT}/live/${d}" ]] && { DEFAULT_FAMILY="$d"; break; }
done

cat > "${ESP_STAGING}/loader/loader.conf" <<EOF
timeout 5
default ${DEFAULT_FAMILY}.conf
console-mode max
EOF

# Default cmdline: no persistence overlay.  dmsquash-live prompts the user
# to "Press [Enter] to continue" if rd.live.overlay= is set but the labeled
# partition is missing (which is the case when booting the pure ISO from
# a CD-ROM or a USB without persistence).  Default tmpfs overlay = no prompt.
CMDLINE_BASE="root=live:CDLABEL=${LABEL} rd.live.image rd.live.dir=LiveOS rd.live.overlay.overlayfs=1 enforcing=0 quiet console=ttyS0,115200n8 console=ttyAMA0,115200n8"

# Persistence-enabled cmdline (used by the persistent-disk variant of each
# loader entry, only meaningful when the SUPERISOPST partition is present).
CMDLINE_PERSIST="${CMDLINE_BASE} rd.live.overlay=LABEL=${PERSIST_LABEL}"

for fam in "${FAMILIES[@]}"; do
    src="${OUT}/live/${fam}"
    [[ -f "${src}/vmlinuz" && -f "${src}/initramfs.img" && -f "${src}/rootfs.sfs" ]] || {
        echo "ERROR: ${src} missing required files" >&2; exit 1; }

    # ESP-side kernel/initramfs (systemd-boot reads exclusively from the FAT)
    mkdir -p "${ESP_STAGING}/images/pxeboot/${fam}"
    cp "${src}/vmlinuz"       "${ESP_STAGING}/images/pxeboot/${fam}/vmlinuz"
    cp "${src}/initramfs.img" "${ESP_STAGING}/images/pxeboot/${fam}/initrd.img"

    # ISO-root copies (Ventoy/loopback boot)
    mkdir -p "${ISO_ROOT}/images/pxeboot/${fam}"
    cp "${src}/vmlinuz"       "${ISO_ROOT}/images/pxeboot/${fam}/vmlinuz"
    cp "${src}/initramfs.img" "${ISO_ROOT}/images/pxeboot/${fam}/initrd.img"

    # Loader entries — two per family: one for ephemeral (tmpfs overlay)
    # and one that opts into the SUPERISOPST persistence partition.  The
    # persistence variant only "works" when booted from a USB that includes
    # the partition (built via `just disk`); on a pure ISO it'll prompt.
    title="Super-ISO Live — ${fam}"
    [[ "$fam" == "$DEFAULT_FAMILY" ]] && title="${title} (default)"
    cat > "${ESP_STAGING}/loader/entries/${fam}.conf" <<EOF
title   ${title}
linux   /images/pxeboot/${fam}/vmlinuz
initrd  /images/pxeboot/${fam}/initrd.img
options ${CMDLINE_BASE} rd.live.squashimg=${fam}.rootfs.sfs superiso.family=${fam}
EOF
    cat > "${ESP_STAGING}/loader/entries/${fam}-persist.conf" <<EOF
title   Super-ISO Live — ${fam} (persistent)
linux   /images/pxeboot/${fam}/vmlinuz
initrd  /images/pxeboot/${fam}/initrd.img
options ${CMDLINE_PERSIST} rd.live.squashimg=${fam}.rootfs.sfs superiso.family=${fam}
EOF

    # Rootfs squashfs in /LiveOS
    cp "${src}/rootfs.sfs" "${ISO_ROOT}/LiveOS/${fam}.rootfs.sfs"
done

# Shared store squashfs
cp "${OUT}/store.sfs" "${ISO_ROOT}/LiveOS/store.squashfs.img"

# ISO-root EFI fallback for firmware that ignores El Torito.
mkdir -p "${ISO_ROOT}/EFI/BOOT"
cp "${EFI_SRC}" "${ISO_ROOT}/${EFI_DEST}"

# Loopback boot menu for Ventoy/GRUB tools.
{
    echo "set timeout=10"
    for fam in "${FAMILIES[@]}"; do
        cat <<EOF
menuentry "Super-ISO Live — ${fam}" {
    linux /images/pxeboot/${fam}/vmlinuz ${CMDLINE_BASE} rd.live.squashimg=${fam}.rootfs.sfs superiso.family=${fam} rd.live.isofile=\${iso_path}
    initrd /images/pxeboot/${fam}/initrd.img
}
EOF
    done
} > "${ISO_ROOT}/boot/grub/loopback.cfg"

# ── Build the FAT ESP ─────────────────────────────────────────────────────────
ESP_DU_KB=$(du -sk "${ESP_STAGING}" | cut -f1)
# +20% slack + 32 MiB for FAT structures
ESP_MB=$(( (ESP_DU_KB * 12 / 10 / 1024) + 32 ))
ESP_IMG="${ISO_ROOT}/EFI/efi.img"
echo ">>> Creating ${ESP_MB} MiB FAT ESP image..."
truncate -s "${ESP_MB}M" "${ESP_IMG}"
mkfs.fat -F 32 -n "ESP" "${ESP_IMG}" >/dev/null

export MTOOLS_SKIP_CHECK=1
mmd -i "${ESP_IMG}" \
    ::/EFI ::/EFI/BOOT \
    ::/loader ::/loader/entries \
    ::/images ::/images/pxeboot

mcopy -i "${ESP_IMG}" "${ESP_STAGING}/${EFI_DEST}"          ::/"${EFI_DEST}"
mcopy -i "${ESP_IMG}" "${ESP_STAGING}/loader/loader.conf"   ::/loader/loader.conf
for fam in "${FAMILIES[@]}"; do
    mmd -i "${ESP_IMG}" "::/images/pxeboot/${fam}"
    mcopy -i "${ESP_IMG}" "${ESP_STAGING}/loader/entries/${fam}.conf"            "::/loader/entries/${fam}.conf"
    mcopy -i "${ESP_IMG}" "${ESP_STAGING}/loader/entries/${fam}-persist.conf"    "::/loader/entries/${fam}-persist.conf"
    mcopy -i "${ESP_IMG}" "${ESP_STAGING}/images/pxeboot/${fam}/vmlinuz"         "::/images/pxeboot/${fam}/vmlinuz"
    mcopy -i "${ESP_IMG}" "${ESP_STAGING}/images/pxeboot/${fam}/initrd.img"      "::/images/pxeboot/${fam}/initrd.img"
done

# ── Assemble the ISO ──────────────────────────────────────────────────────────
echo ">>> Assembling ISO..."
rm -f "${OUTPUT_ISO}"
touch "${OUTPUT_ISO}"
xorriso \
    -dev "stdio:${OUTPUT_ISO}" \
    -volid "${LABEL}" \
    -rockridge on \
    -joliet on \
    -map "${ISO_ROOT}" / \
    -boot_image any platform_id=0xef \
    -boot_image any efi_path=EFI/efi.img \
    -boot_image any part_like_isohybrid=on \
    -boot_image isolinux partition_entry=gpt_basdat \
    -commit

implantisomd5 "${OUTPUT_ISO}" 2>/dev/null || true
echo ">>> Done: ${OUTPUT_ISO} ($(du -sh "${OUTPUT_ISO}" | cut -f1))"
