#!/bin/bash
# End-to-end fisherman install test for a built SuperISO.
# Usage: ./scripts/test-fisherman-install.sh <iso> [ssh-port] [fisherman-binary]

set -euo pipefail

ISO="${1:?Usage: scripts/test-fisherman-install.sh <iso> [ssh-port] [fisherman-binary]}"
shift
PORT=""
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    PORT="$1"
    shift
fi
PORT="${PORT:-33${RANDOM:0:2}}"
FISHERMAN_BIN="${1:-$(command -v fisherman || echo /usr/bin/fisherman)}"
TEST_DIR="${SUPERISO_TEST_DIR:-/var/tmp/superiso-fisherman-ci}"
TARGET="${TEST_DIR}/target.qcow2"
VARS="${TEST_DIR}/OVMF_VARS.fd"
LOG_DIR="${TEST_DIR}/logs"

mkdir -p "$LOG_DIR"

[[ -f "$ISO" ]] || { echo "ERROR: missing $ISO" >&2; exit 1; }
[[ -f "$FISHERMAN_BIN" ]] || { echo "ERROR: missing fisherman binary at $FISHERMAN_BIN" >&2; exit 1; }

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

# Create target disk (empty, for install)
rm -f "$TARGET"
qemu-img create -f qcow2 "$TARGET" 50G >/dev/null

echo ">>> Starting fisherman install test..."
echo "    ISO: $ISO"
echo "    Target: $TARGET"
echo "    Fisherman: $FISHERMAN_BIN"
echo "    Port: $PORT"

# Start QEMU with target disk (not ISO CD)
sudo "$QEMU" \
    -machine q35 -m "${SUPERISO_TEST_MEMORY:-8192}" -smp "${SUPERISO_TEST_CPUS:-4}" \
    -accel kvm -cpu host \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive if=none,id=iso,file="$ISO",media=cdrom,readonly=on,format=raw \
    -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=iso,bootindex=1 \
    -drive if=virtio,format=qcow2,file="$TARGET" \
    -netdev user,id=net0,hostfwd=tcp::${PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -serial file:"${LOG_DIR}/fisherman-serial.log" -display none \
    -pidfile "${LOG_DIR}/fisherman.qemu.pid" &

qemu_pid=$!
cleanup() {
    echo ">>> Cleaning up QEMU (PID: $qemu_pid)"
    kill "$qemu_pid" 2>/dev/null || true
    sudo kill "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for SSH
echo ">>> Waiting for SSH..."
for i in $(seq 1 60); do
    if sshpass -p live ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -p "$PORT" liveuser@127.0.0.1 'true' 2>/dev/null; then
        echo ">>> SSH up after $((i * 2))s"
        break
    fi
    sleep 2
    [[ "$i" -eq 60 ]] && { echo "ERROR: SSH did not come up" >&2; exit 1; }
done

# Copy patched fisherman
echo ">>> Copying fisherman binary..."
sshpass -p live scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$PORT" \
    "$FISHERMAN_BIN" liveuser@127.0.0.1:/tmp/fisherman || { echo "ERROR: Failed to copy fisherman" >&2; exit 1; }

echo ">>> Running install assertions..."
set +e
sshpass -p live ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT" liveuser@127.0.0.1 'bash -x -s' <<'REMOTE'
set -euo pipefail

AUTOSTART=/etc/xdg/autostart/superiso-installer.desktop
[[ -r "$AUTOSTART" ]] || { echo "ERROR: missing installer autostart: $AUTOSTART" >&2; exit 1; }
grep -q 'VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json' "$AUTOSTART" || {
    echo "ERROR: installer autostart does not pass VANILLA_CUSTOM_RECIPE" >&2
    exit 1
}
grep -Eq 'org\.bootcinstaller\.Installer(\.Devel)?' "$AUTOSTART" || {
    echo "ERROR: installer autostart does not launch bootc-installer Flatpak" >&2
    exit 1
}
flatpak list --system --app --columns=application | grep -Eq '^org\.bootcinstaller\.Installer(\.Devel)?$' || {
    echo "ERROR: bootc-installer Flatpak is not installed system-wide" >&2
    exit 1
}
[[ -x /usr/local/bin/fisherman ]] || { echo "ERROR: fisherman backend missing from live image" >&2; exit 1; }

sudo install -m 0755 /tmp/fisherman /usr/local/bin/fisherman

DISK=$(lsblk -dpno NAME,TYPE | awk '$2 == "disk" && $1 !~ /\/dev\/(zram|loop|sr)/ { print $1; exit }')
[[ -b "$DISK" ]] || { echo "ERROR: no target disk found" >&2; exit 1; }

echo ">>> Target disk: $DISK"
echo ">>> /var/tmp mount:"
findmnt -no FSTYPE,SIZE,OPTIONS /var/tmp
findmnt -no FSTYPE /var/tmp | grep -qx tmpfs
# Accept both human (size=16G) and normalized-kib outputs (size=16777216k).
findmnt -no OPTIONS /var/tmp | grep -Eq 'size=(16G|16777216k)'

IMG_JSON=/etc/bootc-installer/images.json
RECIPE_JSON=/etc/bootc-installer/recipe.json
ls -l "$IMG_JSON" "$RECIPE_JSON" || true
[[ -r "$IMG_JSON" ]] || { echo "ERROR: missing $IMG_JSON" >&2; exit 1; }
[[ -r "$RECIPE_JSON" ]] || { echo "ERROR: missing $RECIPE_JSON" >&2; exit 1; }

DEFAULT_IMAGE=$(jq -r '.default_image' "$IMG_JSON")
LOCAL_IMAGE=$(jq -r '.local_imgref' "$RECIPE_JSON")
[[ "$LOCAL_IMAGE" == containers-storage:* ]] || { echo "ERROR: local_imgref must point at containers-storage, got $LOCAL_IMAGE" >&2; exit 1; }
read -r IMAGE FS COMPOSE FAMILY < <(
    jq -r --arg ref "$DEFAULT_IMAGE" '.images[] | select(.imgref == $ref) | [.imgref, .filesystem, .composefs, .family] | @tsv' "$IMG_JSON" | head -1
)
[[ -n "$IMAGE" ]] || { echo "ERROR: default image not found in $IMG_JSON" >&2; exit 1; }

echo ">>> Verifying local catalog images:"
jq -r '.images[].imgref' "$IMG_JSON" | while read -r ref; do
    [[ -n "$ref" ]] || continue
    echo "    $ref"
    sudo podman image exists "$ref" || {
        echo "ERROR: catalog image is not available from local containers-storage: $ref" >&2
        exit 1
    }
done

RECIPE=$(mktemp /tmp/fisherman-ci-recipe.XXXXXX.json)
trap 'rm -f "$RECIPE"' EXIT
jq -n \
    --arg disk "$DISK" \
    --arg image "containers-storage:$IMAGE" \
    --arg fs "$FS" \
    --arg hostname "superiso-ci" \
    --argjson compose "$COMPOSE" \
    '{disk:$disk, filesystem:$fs, image:$image, composeFsBackend:false, selinuxDisabled:true, bootloader:"none", hostname:$hostname, flatpaks:[]}' \
    > "$RECIPE"

timeout 1800 sudo --preserve-env=PATH,HOME,TMPDIR,XDG_RUNTIME_DIR,XDG_DATA_HOME,DBUS_SESSION_BUS_ADDRESS,CONTAINERS_STORAGE_CONF fisherman "$RECIPE" 2>&1 | tee /tmp/fisherman-install.log

PART_COUNT=$(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" { count++ } END { print count + 0 }')
if (( PART_COUNT < 2 )); then
    echo "ERROR: expected installed target disk to have at least 2 partitions, found $PART_COUNT" >&2
    lsblk -f "$DISK" >&2 || true
    exit 1
fi
lsblk -f "$DISK"
REMOTE
INSTALL_RESULT=$?
set -e

if [[ $INSTALL_RESULT -eq 0 ]]; then
    echo ">>> fisherman install SUCCESS"
    exit 0
else
    echo ">>> fisherman install FAILED (exit code: $INSTALL_RESULT)"
    echo ">>> Checking install logs..."
    sshpass -p live ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT" liveuser@127.0.0.1 \
        "cat /tmp/fisherman-install.log" 2>/dev/null || true
    exit 1
fi
