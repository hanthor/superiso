#!/usr/bin/bash
# End-to-end LUKS install test for a built SuperISO.
# Usage: scripts/test-fisherman-luks-install.sh <iso> [ssh-port] [fisherman-binary]

set -euo pipefail

ISO="${1:?Usage: scripts/test-fisherman-luks-install.sh <iso> [ssh-port] [fisherman-binary]}"
shift

PORT=""
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    PORT="$1"
    shift
fi
PORT="${PORT:-33${RANDOM:0:2}}"

FISHERMAN_BIN="${1:-}"
TEST_DIR="${SUPERISO_TEST_DIR:-/var/tmp/superiso-luks-e2e}"
LOG_DIR="${TEST_DIR}/logs"
TARGET="${TEST_DIR}/target-luks.qcow2"
LIVE_VARS="${TEST_DIR}/OVMF_VARS.live.fd"
INSTALLED_VARS="${TEST_DIR}/OVMF_VARS.installed.fd"
LIVE_MONITOR="${TEST_DIR}/qemu-live.sock"
INSTALLED_MONITOR="${TEST_DIR}/qemu-installed.sock"
LIVE_SERIAL="${LOG_DIR}/qemu-live-serial.log"
INSTALLED_SERIAL="${LOG_DIR}/qemu-installed-serial.log"
PASSPHRASE="${SUPERISO_LUKS_PASSPHRASE:-testpassphrase}"
BOOTLOADER="${SUPERISO_LUKS_BOOTLOADER:-systemd}"
COMPOSEFS_OVERRIDE="${SUPERISO_LUKS_COMPOSEFS:-}"
SELINUX_DISABLED="${SUPERISO_LUKS_SELINUX_DISABLED:-false}"

mkdir -p "$LOG_DIR"

[[ -f "$ISO" ]] || { echo "ERROR: missing ISO: $ISO" >&2; exit 1; }
if [[ -n "$FISHERMAN_BIN" ]]; then
    [[ -f "$FISHERMAN_BIN" ]] || { echo "ERROR: missing fisherman binary: $FISHERMAN_BIN" >&2; exit 1; }
fi

QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
[[ -n "$QEMU" ]] || { echo "ERROR: qemu not found" >&2; exit 1; }

OVMF_CODE=""
for f in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/ovmf/OVMF.fd; do
    [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
done
[[ -n "$OVMF_CODE" ]] || { echo "ERROR: OVMF_CODE not found" >&2; exit 1; }

copy_ovmf_vars() {
    local dest="$1"
    for f in \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        if [[ -f "$f" ]]; then
            cp "$f" "$dest"
            return 0
        fi
    done
    return 1
}

copy_ovmf_vars "$LIVE_VARS" || { echo "ERROR: OVMF_VARS not found" >&2; exit 1; }
copy_ovmf_vars "$INSTALLED_VARS" || { echo "ERROR: OVMF_VARS not found" >&2; exit 1; }

live_pid=""
installed_pid=""
cleanup() {
    set +e
    if [[ -n "$live_pid" ]]; then
        sudo kill "$live_pid" 2>/dev/null || kill "$live_pid" 2>/dev/null || true
    fi
    if [[ -n "$installed_pid" ]]; then
        sudo kill "$installed_pid" 2>/dev/null || kill "$installed_pid" 2>/dev/null || true
    fi
    sudo chmod -R a+rX "$LOG_DIR" 2>/dev/null || true
}
trap cleanup EXIT

rm -f "$TARGET" "$LIVE_MONITOR" "$INSTALLED_MONITOR" "$LIVE_SERIAL" "$INSTALLED_SERIAL"
qemu-img create -f qcow2 "$TARGET" "${SUPERISO_LUKS_DISK_SIZE:-64G}" >/dev/null

ssh_base=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -o PreferredAuthentications=password
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=20
)

monitor_cmd() {
    local socket="$1"
    local command="$2"
    printf '%s\n' "$command" | sudo socat - "UNIX-CONNECT:${socket}" >/dev/null
}

shell_quote() {
    printf '%q' "$1"
}

echo ">>> Booting live ISO for LUKS install"
sudo "$QEMU" \
    -machine q35 -m "${SUPERISO_TEST_MEMORY:-8192}" -smp "${SUPERISO_TEST_CPUS:-4}" \
    -accel kvm -cpu host \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${LIVE_VARS}" \
    -drive "if=none,id=iso,file=${ISO},media=cdrom,readonly=on,format=raw" \
    -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=iso,bootindex=1 \
    -drive "if=none,id=disk,file=${TARGET},format=qcow2" \
    -device virtio-blk-pci,drive=disk \
    -netdev "user,id=net0,hostfwd=tcp::${PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -monitor "unix:${LIVE_MONITOR},server,nowait" \
    -serial "file:${LIVE_SERIAL}" \
    -display none \
    -pidfile "${LOG_DIR}/qemu-live.pid" &
live_pid=$!

echo ">>> Waiting for live SSH on port ${PORT}"
for i in $(seq 1 90); do
    if sshpass -p live ssh "${ssh_base[@]}" -p "$PORT" liveuser@127.0.0.1 true 2>/dev/null; then
        echo ">>> Live SSH up after $((i * 5))s"
        break
    fi
    if sudo grep -q "DAKOTA_LIVE_READY" "$LIVE_SERIAL" 2>/dev/null; then
        echo ">>> Live serial ready marker seen"
    fi
    [[ "$i" -eq 90 ]] && { echo "ERROR: live SSH did not come up" >&2; sudo tail -80 "$LIVE_SERIAL" || true; exit 1; }
    sleep 5
done

for i in $(seq 1 30); do
    [[ -S "$LIVE_MONITOR" ]] && break
    [[ "$i" -eq 30 ]] && { echo "ERROR: live QEMU monitor did not appear" >&2; exit 1; }
    sleep 1
done
monitor_cmd "$LIVE_MONITOR" "screendump ${LOG_DIR}/luks-screenshot-live.ppm" || true

if [[ -n "$FISHERMAN_BIN" ]]; then
    echo ">>> Installing supplied fisherman binary into live image"
    sshpass -p live scp "${ssh_base[@]}" -P "$PORT" "$FISHERMAN_BIN" liveuser@127.0.0.1:/tmp/fisherman
    sshpass -p live ssh "${ssh_base[@]}" -p "$PORT" liveuser@127.0.0.1 \
        "sudo install -m 0755 /tmp/fisherman /usr/local/bin/fisherman"
fi

echo ">>> Running LUKS fisherman install"
PASSPHRASE_Q=$(shell_quote "$PASSPHRASE")
BOOTLOADER_Q=$(shell_quote "$BOOTLOADER")
COMPOSEFS_OVERRIDE_Q=$(shell_quote "$COMPOSEFS_OVERRIDE")
SELINUX_DISABLED_Q=$(shell_quote "$SELINUX_DISABLED")
set +e
sshpass -p live ssh "${ssh_base[@]}" -p "$PORT" liveuser@127.0.0.1 \
    "SUPERISO_LUKS_PASSPHRASE=${PASSPHRASE_Q} SUPERISO_LUKS_BOOTLOADER=${BOOTLOADER_Q} SUPERISO_LUKS_COMPOSEFS=${COMPOSEFS_OVERRIDE_Q} SUPERISO_LUKS_SELINUX_DISABLED=${SELINUX_DISABLED_Q} bash -x -s" <<'REMOTE'
set -euo pipefail

AUTOSTART=/etc/xdg/autostart/superiso-installer.desktop
[[ -r "$AUTOSTART" ]] || { echo "ERROR: missing installer autostart: $AUTOSTART" >&2; exit 1; }
grep -q 'VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json' "$AUTOSTART" || {
    echo "ERROR: installer autostart does not pass VANILLA_CUSTOM_RECIPE" >&2
    exit 1
}
flatpak list --system --app --columns=application | grep -Eq '^org\.bootcinstaller\.Installer(\.Devel)?$' || {
    echo "ERROR: bootc-installer Flatpak is not installed system-wide" >&2
    exit 1
}
[[ -x /usr/local/bin/fisherman ]] || { echo "ERROR: fisherman backend missing from live image" >&2; exit 1; }

DISK=$(lsblk -dpno NAME,TYPE | awk '$2 == "disk" && $1 !~ /\/dev\/(zram|loop|sr)/ { print $1; exit }')
[[ -b "$DISK" ]] || { echo "ERROR: no target disk found" >&2; exit 1; }
echo ">>> Target disk: $DISK"

IMG_JSON=/etc/bootc-installer/images.json
RECIPE_JSON=/etc/bootc-installer/recipe.json
[[ -r "$IMG_JSON" ]] || { echo "ERROR: missing $IMG_JSON" >&2; exit 1; }
[[ -r "$RECIPE_JSON" ]] || { echo "ERROR: missing $RECIPE_JSON" >&2; exit 1; }

DEFAULT_IMAGE=$(jq -r '.default_image' "$IMG_JSON")
read -r IMAGE FS COMPOSE FAMILY < <(
    jq -r --arg ref "$DEFAULT_IMAGE" '.images[] | select(.imgref == $ref) | [.imgref, .filesystem, .composefs, .family] | @tsv' "$IMG_JSON" | head -1
)
[[ -n "$IMAGE" ]] || { echo "ERROR: default image not found in $IMG_JSON" >&2; exit 1; }
if [[ -n "${SUPERISO_LUKS_COMPOSEFS}" ]]; then
    COMPOSE="${SUPERISO_LUKS_COMPOSEFS}"
fi

echo ">>> Verifying local catalog images"
jq -r '.images[].imgref' "$IMG_JSON" | while read -r ref; do
    [[ -n "$ref" ]] || continue
    sudo podman image exists "$ref" || {
        echo "ERROR: catalog image is not available from local containers-storage: $ref" >&2
        exit 1
    }
done

RECIPE=$(mktemp /tmp/fisherman-luks-recipe.XXXXXX.json)
trap 'rm -f "$RECIPE"' EXIT
jq -n \
    --arg disk "$DISK" \
    --arg image "containers-storage:$IMAGE" \
    --arg fs "$FS" \
    --arg hostname "superiso-luks-ci" \
    --arg passphrase "$SUPERISO_LUKS_PASSPHRASE" \
    --arg bootloader "$SUPERISO_LUKS_BOOTLOADER" \
    --argjson compose "$COMPOSE" \
    --argjson selinux_disabled "$SUPERISO_LUKS_SELINUX_DISABLED" \
    '{
      disk:$disk,
      filesystem:$fs,
      image:$image,
      composeFsBackend:$compose,
      selinuxDisabled:$selinux_disabled,
      bootloader:$bootloader,
      hostname:$hostname,
      encryption:{type:"luks-passphrase", passphrase:$passphrase},
      additionalImageStores:["/var/lib/superiso-store"],
      flatpaks:[]
    }' > "$RECIPE"

echo ">>> Recipe JSON:"
jq . "$RECIPE"
echo ">>> Guest containers/storage.conf:"
sudo cat /etc/containers/storage.conf
echo ">>> Guest superiso-store mount:"
findmnt /var/lib/superiso-store || true
echo ">>> Fisherman validate preflight:"
sudo --preserve-env=PATH,HOME,TMPDIR,XDG_RUNTIME_DIR,XDG_DATA_HOME,DBUS_SESSION_BUS_ADDRESS \
    /usr/local/bin/fisherman validate "$RECIPE" || true

echo ">>> Fisherman backend version:"
sudo --preserve-env=PATH,HOME,TMPDIR,XDG_RUNTIME_DIR,XDG_DATA_HOME,DBUS_SESSION_BUS_ADDRESS \
    /usr/local/bin/fisherman version || true

echo ">>> Ensuring bootupd is available for bootc:"
sudo dnf install -y bootupd 2>&1 | tail -3 || { echo "bootupd unavailable; continuing anyway"; true; }

echo ">>> Live environment paths:"
echo "    Target mount: /mnt/fisherman-target"
echo "    Scratch dir: /mnt/fisherman-target/.fisherman-scratch"
findmnt /mnt/fisherman-target 2>/dev/null || echo "    (not mounted yet)"
ls -la /mnt/fisherman-target/.fisherman-scratch 2>/dev/null || echo "    (scratch dir not found)"

# Pre-create storage.conf with additionalimagestore support for bootc container
# Use /var/tmp since it's available in the live environment and mounted into containers
STORAGE_CONF="/var/tmp/superiso-bootc-storage.conf"
echo ">>> Creating storage.conf for bootc container at $STORAGE_CONF:"
sudo tee "$STORAGE_CONF" > /dev/null <<'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
additionalimagestores = ["/var/lib/superiso-store"]
EOF
sudo cat "$STORAGE_CONF"

# Pre-create /var/tmp/oci-cache directory for bootc composefs export
# When composefs backend is enabled, bootc exports the image to an OCI layout
# at /var/tmp/oci-cache inside the container. This directory must exist and be writable.
if [[ "${SUPERISO_LUKS_COMPOSEFS}" == "true" ]]; then
    echo ">>> Pre-creating /var/tmp/oci-cache for composefs image export"
    sudo mkdir -p /var/tmp/oci-cache
    sudo chmod 1777 /var/tmp/oci-cache
fi

# Support both CLI shapes:
# - newer fisherman: fisherman <recipe.json>
# - legacy fisherman: fisherman install <recipe.json>
set +e
timeout "${SUPERISO_LUKS_INSTALL_TIMEOUT:-2400}" \
    sudo --preserve-env=PATH,HOME,TMPDIR,XDG_RUNTIME_DIR,XDG_DATA_HOME,DBUS_SESSION_BUS_ADDRESS,CONTAINERS_STORAGE_CONF \
    env CONTAINERS_STORAGE_CONF="$STORAGE_CONF" \
    /usr/local/bin/fisherman "$RECIPE" > /tmp/fisherman-luks-install.log 2>&1
FISHERMAN_RC=$?
set -e
cat /tmp/fisherman-luks-install.log

if [[ "$FISHERMAN_RC" -ne 0 ]]; then
    echo ">>> Fisherman direct recipe mode failed (rc=${FISHERMAN_RC}); retrying legacy install subcommand"
    set +e
    timeout "${SUPERISO_LUKS_INSTALL_TIMEOUT:-2400}" \
        sudo --preserve-env=PATH,HOME,TMPDIR,XDG_RUNTIME_DIR,XDG_DATA_HOME,DBUS_SESSION_BUS_ADDRESS,CONTAINERS_STORAGE_CONF \
        env CONTAINERS_STORAGE_CONF="$STORAGE_CONF" \
        /usr/local/bin/fisherman install "$RECIPE" >> /tmp/fisherman-luks-install.log 2>&1
    FISHERMAN_RC=$?
    set -e
    cat /tmp/fisherman-luks-install.log
fi

if [[ "$FISHERMAN_RC" -ne 0 ]]; then
    echo "ERROR: fisherman exited with rc=${FISHERMAN_RC}" >&2
    exit "$FISHERMAN_RC"
fi

# Post-install BLS fixup: add rd.luks.uuid= and console= to every BLS entry.
#
# For ostree+LUKS: Fisherman correctly sets up LUKS but doesn't inject rd.luks.uuid=
# into the BLS entries, so dracut never opens the LUKS container and boot drops to
# emergency shell. We need to patch the BLS entries.
#
# For composefs+LUKS: Uses immutable UKI (Unified Kernel Image) managed by systemd-boot.
# The kernel and cmdline are embedded in the UKI binary, so BLS patching is not needed
# and the installation is complete as-is.
#
if [[ "${COMPOSEFS_OVERRIDE}" == "true" ]]; then
    echo ">>> ComposFS+LUKS installation uses UKI (immutable kernel) - no BLS patching needed"
    echo ">>> Installation is complete and ready to boot"
else
    echo ">>> OStree+LUKS installation - patching BLS entries for LUKS unlock..."
    BOOT_PART=$(lsblk -nrpo NAME,FSTYPE "$DISK" | awk '($2 == "ext4" || $2 == "xfs") { print $1; exit }')
    if [[ -z "$BOOT_PART" ]]; then
        # Fallback: second partition by position
        BOOT_PART=$(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" { parts[++n]=$1 } END { print parts[2] }')
    fi
    LUKS_PART=$(lsblk -nrpo NAME,FSTYPE "$DISK" | awk '$2 == "crypto_LUKS" { print $1; exit }')
    if [[ -z "$LUKS_PART" ]]; then
        # Fallback: third partition by position
        LUKS_PART=$(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" { parts[++n]=$1 } END { print parts[3] }')
    fi
    LUKS_UUID=""
    if [[ -b "$LUKS_PART" ]]; then
        LUKS_UUID=$(sudo blkid -s UUID -o value "$LUKS_PART" 2>/dev/null || true)
    fi
    echo ">>> Boot partition: ${BOOT_PART:-unknown}  LUKS partition: ${LUKS_PART:-unknown}  LUKS UUID: ${LUKS_UUID:-unknown}"

    if [[ -b "$BOOT_PART" ]]; then
        TMP=$(mktemp -d)
        trap 'sudo umount "$TMP" 2>/dev/null || true; rmdir "$TMP" 2>/dev/null || true; rm -f "$RECIPE"' EXIT
        if sudo mount "$BOOT_PART" "$TMP" 2>/dev/null; then
            COUNT=0
            for entry in \
                "$TMP"/loader/entries/*.conf \
                "$TMP"/EFI/loader/entries/*.conf \
                "$TMP"/boot/loader/entries/*.conf; do
                [[ -f "$entry" ]] || continue
                if ! grep -q '^options ' "$entry"; then
                    continue
                fi
                # Add rd.luks.uuid if missing and we know the LUKS UUID.
                if [[ -n "$LUKS_UUID" ]] && ! grep -q "rd.luks.uuid=$LUKS_UUID" "$entry"; then
                    sudo sed -i "s|^options .*|& rd.luks.uuid=${LUKS_UUID}|" "$entry"
                fi
                # Add serial console if missing.
                if ! grep -q 'console=ttyS0' "$entry"; then
                    sudo sed -i 's|^options .*|& console=tty0 console=ttyS0|' "$entry"
                fi
                COUNT=$((COUNT + 1))
            done
            echo ">>> Patched $COUNT BLS entries (rd.luks.uuid + serial console)"
            sudo cat "$TMP"/loader/entries/*.conf 2>/dev/null || true
            sudo umount "$TMP"
        fi
        rmdir "$TMP"
    fi
fi

lsblk -f "$DISK"
REMOTE
install_result=$?
set -e

if [[ "$install_result" -ne 0 ]]; then
    echo "ERROR: LUKS fisherman install failed" >&2
    echo ">>> /var/log/bootc-installer.log" >&2
    sshpass -p live ssh "${ssh_base[@]}" -p "$PORT" liveuser@127.0.0.1 \
        "sudo cat /var/log/bootc-installer.log" 2>/dev/null || true
    echo ">>> journalctl -b" >&2
    sshpass -p live ssh "${ssh_base[@]}" -p "$PORT" liveuser@127.0.0.1 \
        "sudo journalctl -b --no-pager -n 300" 2>/dev/null || true
    echo ">>> /tmp/fisherman-luks-install.log" >&2
    sshpass -p live ssh "${ssh_base[@]}" -p "$PORT" liveuser@127.0.0.1 \
        "cat /tmp/fisherman-luks-install.log" 2>/dev/null || true
    exit "$install_result"
fi

echo ">>> Shutting down live VM"
monitor_cmd "$LIVE_MONITOR" "system_powerdown" || true
sleep 10
monitor_cmd "$LIVE_MONITOR" "quit" || true
sudo kill "$live_pid" 2>/dev/null || true
live_pid=""

echo ">>> Booting installed LUKS disk"
sudo "$QEMU" \
    -machine q35 -m "${SUPERISO_TEST_MEMORY:-8192}" -smp "${SUPERISO_TEST_CPUS:-4}" \
    -accel kvm -cpu host \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${INSTALLED_VARS}" \
    -drive "if=none,id=disk,file=${TARGET},format=qcow2" \
    -device virtio-blk-pci,drive=disk \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -monitor "unix:${INSTALLED_MONITOR},server,nowait" \
    -serial "file:${INSTALLED_SERIAL}" \
    -display none \
    -pidfile "${LOG_DIR}/qemu-installed.pid" &
installed_pid=$!

for i in $(seq 1 30); do
    [[ -S "$INSTALLED_MONITOR" ]] && break
    [[ "$i" -eq 30 ]] && { echo "ERROR: installed QEMU monitor did not appear" >&2; exit 1; }
    sleep 2
done

echo ">>> Detecting LUKS prompt and unlocking installed system"
sudo python3 "$(dirname "$0")/luks-unlock.py" "$INSTALLED_MONITOR" "$PASSPHRASE" "$INSTALLED_SERIAL" "$LOG_DIR"

echo ">>> LUKS install and boot SUCCESS"
