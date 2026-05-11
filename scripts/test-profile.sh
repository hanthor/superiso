#!/usr/bin/bash
# Minimal VM smoke test for one built profile ISO.
# Boots ISO, waits for SSH liveuser:live, and verifies the offline store is
# mounted and images are visible via podman.

set -euo pipefail

PROFILE="${1:?Usage: scripts/test-profile.sh <profile> [ssh-port]}"
PORT="${2:-33${RANDOM:0:2}}"
OUTPUT_BASE="${SUPERISO_OUTPUT_BASE:-output}"
ISO="${OUTPUT_BASE}/${PROFILE}/superiso-live.iso"
TARGET="/var/tmp/superiso-${PROFILE}-target.qcow2"
VARS="/var/tmp/superiso-${PROFILE}-vars.fd"

[[ -f "$ISO" ]] || { echo "ERROR: missing $ISO" >&2; exit 1; }

QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
[[ -n "$QEMU" ]] || { echo "ERROR: qemu not found" >&2; exit 1; }

OVMF_CODE=""
for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
done
[[ -n "$OVMF_CODE" ]] || { echo "ERROR: OVMF_CODE not found" >&2; exit 1; }

for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
    [[ -f "$f" ]] && { cp "$f" "$VARS"; break; }
done
[[ -f "$VARS" ]] || { echo "ERROR: OVMF_VARS not found" >&2; exit 1; }

qemu-img create -f qcow2 "$TARGET" 64G >/dev/null

sudo "$QEMU" \
    -machine q35 -m "${SUPERISO_TEST_MEMORY:-16384}" -smp "${SUPERISO_TEST_CPUS:-4}" \
    -accel kvm -cpu host \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive if=none,id=iso,file="$ISO",media=cdrom,readonly=on,format=raw \
    -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=iso \
    -drive if=virtio,format=qcow2,file="$TARGET" \
    -netdev user,id=net0,hostfwd=tcp::${PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -serial file:"${OUTPUT_BASE}/logs/${PROFILE}-serial.log" -display none \
    -pidfile "${OUTPUT_BASE}/logs/${PROFILE}.qemu.pid" &

pid=$!
cleanup() {
    kill "$pid" 2>/dev/null || true
    sudo kill "$pid" 2>/dev/null || true
}
trap cleanup EXIT

for i in $(seq 1 120); do
    if sshpass -p live ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -p "$PORT" liveuser@127.0.0.1 'true' 2>/dev/null; then
        echo ">>> [${PROFILE}] SSH up after $((i * 3))s"
        break
    fi
    sleep 3
    [[ "$i" -eq 120 ]] && { echo "ERROR: SSH did not come up" >&2; exit 1; }
done

sshpass -p live ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT" liveuser@127.0.0.1 '
    set -euo pipefail
    echo "--- df /var/tmp ---"
    df -h /var/tmp
    echo "--- superiso store ---"
    mount | grep superiso-store
    echo "--- offline images ---"
    sudo podman images
'

echo ">>> [${PROFILE}] smoke test passed"
