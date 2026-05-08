#!/usr/bin/bash
# build-disk.sh <iso-input> <disk-output> [persist-mb]
#
# Wraps a hybrid ISO into a multi-partition raw disk image so the resulting
# USB doubles as a portable workstation:
#
#   GPT layout:
#     1.  ISO9660 (the live ISO contents — read-only, contains kernel+squashfs)
#     2.  ext4    (label: SUPERISOPST — persistent /home + extra container images)
#
# The ISO is already hybrid (xorriso + part_like_isohybrid in build-iso.sh),
# so partition 1 is bootable as-is via the EFI El Torito catalog.  Partition 2
# is appended after the ISO and registered in a new GPT table that supersedes
# the ISO's hybrid one.
#
# A firstboot service (live/src/systemd/superiso-firstboot.service) grows the
# persistence partition to the full device size on first boot.
#
# Usage:
#   build-disk.sh output/superiso-live.iso output/superiso.img        # 8G persist
#   build-disk.sh output/superiso-live.iso output/superiso.img 32768  # 32G persist

set -euo pipefail

ISO="${1:?Usage: build-disk.sh <iso-input> <disk-output> [persist-mb]}"
OUT="${2:?Usage: build-disk.sh <iso-input> <disk-output> [persist-mb]}"
PERSIST_MB="${3:-8192}"

[[ -f "$ISO" ]] || { echo "ERROR: $ISO not found" >&2; exit 1; }

ISO_BYTES=$(stat -c %s "$ISO")
ALIGN_MB=4
ISO_MB=$(( (ISO_BYTES + 1024*1024 - 1) / (1024*1024) ))
# Round up to ALIGN_MB boundary so partition 2 starts aligned.
ISO_MB=$(( (ISO_MB + ALIGN_MB - 1) / ALIGN_MB * ALIGN_MB ))
TOTAL_MB=$(( ISO_MB + PERSIST_MB + 4 ))   # +4 MiB headroom for GPT backup header

echo ">>> ISO size:        ${ISO_MB} MiB"
echo ">>> Persistence:     ${PERSIST_MB} MiB"
echo ">>> Total disk size: ${TOTAL_MB} MiB"

rm -f "$OUT"
truncate -s "${TOTAL_MB}M" "$OUT"

# Copy ISO into the front of the disk.  dd preserves the hybrid MBR/GPT and
# El Torito boot catalog xorriso laid down — UEFI firmware will still find
# the ESP via partition 1.
dd if="$ISO" of="$OUT" bs=1M conv=notrunc status=none

# Replace the (ISO-laid) protective GPT with one we control:
#   Part 1: ISO9660 region, type 0x0FC63DAF (Linux filesystem)
#   Part 2: ext4 persistence, type 0x0FC63DAF, label SUPERISOPST
#
# sgdisk -Z wipes existing GPT/MBR; -o creates fresh GPT.
# Sector size is 512 — ISO_MB * 2048 = end sector of partition 1.
P1_END_SEC=$(( ISO_MB * 2048 ))
P2_START_SEC=$(( P1_END_SEC + 1 ))

# Preserve the ISO's existing hybrid GPT (xorriso laid down EFI System
# Partition + protective MBR pointing to the embedded ESP).  Use parted to
# ADD a new partition for persistence — parted modifies the GPT in-place
# instead of replacing it.  GNU parted refuses to operate on raw images
# whose backup GPT header is missing, so we first run `parted ... print fix`
# which rebuilds the backup header at the new end-of-disk after our truncate.
P2_END_SEC=$(( (TOTAL_MB - 2) * 2048 ))

# Move/recreate GPT backup to end-of-disk (we extended the disk with truncate).
echo Fix | sudo /usr/sbin/parted ---pretend-input-tty "$OUT" print 2>/dev/null || true

# Detect whether the ISO laid down GPT or MBR — parted's mkpart syntax differs.
TABLE=$(sudo /usr/sbin/parted -s "$OUT" print 2>/dev/null \
    | awk -F': ' '/Partition Table/{print $2}')
echo ">>> ISO partition table: ${TABLE}"

case "$TABLE" in
    gpt)
        sudo /usr/sbin/parted -s "$OUT" mkpart superiso-persist ext4 \
            "$(( P2_START_SEC ))s" "$(( P2_END_SEC ))s"
        ;;
    msdos|*)
        sudo /usr/sbin/parted -s "$OUT" mkpart primary ext4 \
            "$(( P2_START_SEC ))s" "$(( P2_END_SEC ))s"
        ;;
esac

# Format the new partition.  losetup --partscan exposes /dev/loopXp{1,2,3}.
LOOP=$(sudo losetup --find --show --partscan "$OUT")
trap "sudo losetup -d '${LOOP}' 2>/dev/null || true" EXIT

# Identify the persistence partition by its start sector (we just created it
# at P2_START_SEC).  Picking by partition number is wrong because parted may
# reuse a freed table slot, putting the new partition at a lower number than
# the pre-existing ESP — formatting "the highest-numbered partition" can
# nuke the ESP.
PERSIST_DEV=""
for p in "${LOOP}"p*; do
    start=$(cat "/sys/class/block/$(basename $p)/start" 2>/dev/null || echo 0)
    if [[ "$start" -eq "$P2_START_SEC" ]]; then
        PERSIST_DEV="$p"; break
    fi
done
[[ -n "$PERSIST_DEV" ]] || { echo "ERROR: couldn't locate persistence partition (start=${P2_START_SEC})" >&2; exit 1; }
echo ">>> Formatting ${PERSIST_DEV} as ext4 SUPERISOPST"
sudo mkfs.ext4 -F -L SUPERISOPST -E lazy_itable_init=1,lazy_journal_init=1 "${PERSIST_DEV}" >/dev/null

echo ">>> Wrote: $OUT ($(du -sh "$OUT" | cut -f1))"
echo ""
echo "Write to USB with:"
echo "  sudo dd if=$OUT of=/dev/sdX bs=4M status=progress conv=fsync"
