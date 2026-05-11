# Super-ISO build orchestration (multi-bootable architecture).
#
# Pipeline:
#   1. stage         skopeo-pull every payload row into a shared overlay
#                    containers-storage at output/cs-staging
#   2. live-envs     for each row with live=true, build a per-family live
#                    container, render images.<family>.json, and emit
#                    output/live/<family>/{vmlinuz, initramfs.img, rootfs.sfs, EFI/}
#   3. store-sqfs    mksquashfs the shared containers-storage → output/store.sfs
#   4. iso           assemble multi-boot UEFI ISO (one menu entry per family)
#   5. disk          (optional) wrap ISO into a hybrid raw .img with a writable
#                    persistence partition labeled SUPERISOPST
#
# Knobs:
#   compression=fast|release       fast = zstd-3/128K, release = zstd-15/1M
#   payloads=path/to/manifest.tsv  override default payloads.tsv
#   output_dir=...                 override output location
#   persist_mb=8192                size of persistence partition in disk image

output_dir   := "output"
payloads     := "payloads.tsv"
compression  := "fast"
persist_mb   := "8192"

default: iso

# Convenience target for end-to-end build.
all: stage live-envs store-sqfs iso

# Pull every payload into the shared overlay-driver containers-storage.
# Idempotent: skopeo skips images already present at the same digest.
stage:
    #!/usr/bin/bash
    set -euo pipefail
    mkdir -p {{output_dir}}
    OUT=$(realpath {{output_dir}})
    CS_STAGING="${OUT}/cs-staging"
    mkdir -p "${CS_STAGING}"
    # Skopeo runs inside a container so the tar-split format it writes
    # matches the containers/storage version that will read it at install
    # time.  Prefer a previously-built superiso-live-* image; otherwise any
    # ublue image we've already pulled; finally fall back to skopeo:stable.
    set +o pipefail
    HOST_IMG=$(podman images | awk '/^localhost\/superiso-live-/ {print $1":"$2; exit}')
    if [[ -z "${HOST_IMG}" ]]; then
        HOST_IMG=$(podman images | awk '/ublue-os\/(bazzite|bluefin|aurora)/ {print $1":"$2; exit}')
    fi
    set -o pipefail
    if [[ -z "${HOST_IMG}" ]]; then
        echo ">>> Pulling bootstrap host image (skopeo runner)..."
        podman pull quay.io/skopeo/stable:latest
        HOST_IMG=quay.io/skopeo/stable:latest
    fi
    echo ">>> Using ${HOST_IMG} as skopeo host"
    bash scripts/stage-payloads.sh {{payloads}} "${CS_STAGING}" "${HOST_IMG}"

# Build per-family live env artefacts in sequence.
# Sequential (not parallel) because each `mksquashfs -processors 4` already
# saturates 4 cores and parallelism would thrash disk + RAM on tight hosts.
live-envs:
    #!/usr/bin/bash
    set -euo pipefail
    OUT=$(realpath {{output_dir}})
    while IFS=$'\t' read -r ref name desc fs cfs family live; do
        case "$ref" in ''|\#*) continue ;; esac
        [[ "$live" == "true" ]] || continue
        echo "================================================================"
        echo " [LIVE] family=${family}  ref=${ref}"
        echo "================================================================"
        SUPERISO_COMPRESSION={{compression}} \
            bash scripts/build-live-env.sh {{payloads}} "${family}" "${ref}" "${OUT}"
    done < {{payloads}}

# Squashfs the shared containers-storage tree.
store-sqfs:
    #!/usr/bin/bash
    set -euo pipefail
    OUT=$(realpath {{output_dir}})
    SUPERISO_COMPRESSION={{compression}} \
        bash scripts/build-store-sqfs.sh "${OUT}/cs-staging" "${OUT}/store.sfs"

# Assemble the multi-boot ISO.
iso:
    #!/usr/bin/bash
    set -euo pipefail
    OUT=$(realpath {{output_dir}})
    TMPDIR="${OUT}" \
    PATH="/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}" \
        bash scripts/build-iso.sh "${OUT}" "${OUT}/superiso-live.iso"

# Wrap the ISO in a raw disk image with a SUPERISOPST persistence partition.
disk:
    #!/usr/bin/bash
    set -euo pipefail
    OUT=$(realpath {{output_dir}})
    bash scripts/build-disk.sh "${OUT}/superiso-live.iso" "${OUT}/superiso.img" {{persist_mb}}

# Boot the multi-boot ISO under QEMU/UEFI.  Detach: Ctrl-A X.
boot:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu not found" >&2; exit 1; }
    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    OVMF_VARS=$(mktemp /tmp/superiso-ovmf-vars.XXXXXX.fd)
    for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { cp "$f" "${OVMF_VARS}"; break; }
    done
    [[ -f /tmp/superiso-target.qcow2 ]] || qemu-img create -f qcow2 /tmp/superiso-target.qcow2 64G >/dev/null
    sudo "$QEMU" \
        -machine q35 -m 8192 -smp 4 -accel kvm -cpu host \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=iso,file={{output_dir}}/superiso-live.iso,media=cdrom,readonly=on,format=raw \
        -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=iso \
        -drive if=virtio,format=qcow2,file=/tmp/superiso-target.qcow2 \
        -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
        -serial mon:stdio -display none -no-reboot

clean:
    rm -rf {{output_dir}}/cs-staging {{output_dir}}/live {{output_dir}}/store.sfs \
           {{output_dir}}/superiso-live.iso {{output_dir}}/superiso.img \
           live/src/etc/bootc-installer/images.*.json
    podman images --format '{{{{.Repository}}}}' | grep -E '^localhost/superiso-live-' \
        | xargs -r -I{} podman rmi {} || true

# Show what's currently staged + what would be built.
status:
    @echo "─── payloads.tsv ──"
    @awk -F'\t' '/^[^#]/ && NF>=7 {printf "  %-45s family=%-8s live=%s\n", $1, $6, $7}' {{payloads}}
    @echo
    @echo "─── built live envs in {{output_dir}}/live ──"
    @if [[ -d {{output_dir}}/live ]]; then \
        for d in {{output_dir}}/live/*/; do \
            f=$(basename "$d"); \
            sz=$(du -sh "$d/rootfs.sfs" 2>/dev/null | cut -f1); \
            echo "  $f → $sz"; \
        done; \
    else echo "  (none)"; fi
    @echo
    @echo "─── disk usage ──"
    @mkdir -p {{output_dir}}
    @df -h {{output_dir}}

# Build a named profile from profiles/<profile>.tsv into output/<profile>/.
profile name:
    just payloads=profiles/{{name}}.tsv output_dir=output/{{name}} compression={{compression}} all

# Build Dakota, Aurora, Bluefin, and Bazzite concurrently, each into its own
# output/<profile>/ directory by default. Tune concurrency with
# SUPERISO_PROFILE_JOBS and place large builds elsewhere with
# SUPERISO_OUTPUT_BASE=/var/tmp/superiso-output.
profiles:
    SUPERISO_COMPRESSION={{compression}} scripts/build-profiles.sh dakota aurora bluefin bazzite

# Build the larger all-uBlue experiment.
gold:
    just payloads=profiles/gold-ublue.tsv output_dir=output/gold-ublue compression={{compression}} all

# Smoke-test a built profile ISO in QEMU. Example: just test-profile bluefin
test-profile name:
    scripts/test-profile.sh {{name}}
