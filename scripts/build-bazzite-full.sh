#!/usr/bin/bash
# scripts/build-bazzite-full.sh
#
# Builds the Bazzite Full SuperISO:
#   - Three live boot environments (KDE NVIDIA, GNOME NVIDIA, Deck)
#   - Six offline install payloads in a shared containers-storage squashfs
#   - bootc-installer Flatpak pre-installed in each live env
#   - Compresses to .iso.xz for distribution
#
# Usage:
#   scripts/build-bazzite-full.sh [output-dir]
#
# Defaults:
#   output-dir   /var/mnt/data/bazzite-full
#
# Environment overrides:
#   SUPERISO_COMPRESSION   "fast" (default) or "release"
#   INSTALLER_CHANNEL      "stable" (default) or "dev"
#   SKIP_CONTAINER_BUILD   "1" to reuse previously built localhost/ images
#   SKIP_PULL              "1" to skip registry pulls (offline rebuild)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/var/mnt/data/bazzite-full}"
ISO="${OUT}/bazzite-full.iso"
TBX="${REPO}/tacklebox/tacklebox"
CF="${REPO}/live/Containerfile.generic"

mkdir -p "${OUT}"

# ── Build tacklebox binary ───────────────────────────────────────────────────
if [[ ! -x "${TBX}" ]] || [[ "${REPO}/tacklebox/go.sum" -nt "${TBX}" ]]; then
    echo ">>> Building tacklebox binary..."
    (cd "${REPO}/tacklebox" && go build -o tacklebox ./cmd/tacklebox)
fi

# ── Container image builds ───────────────────────────────────────────────────
# Each live env is the upstream Bazzite image transformed via
# Containerfile.generic, which:
#   - Rebuilds initramfs with dmsquash-live support (Debian helper stage)
#   - Installs the bootc-installer Flatpak (offline capable)
#   - Configures autologin + liveuser + polkit + sshd
#   - Writes images.json + recipe.json for the installer picker
#   - Configures storage.conf with additionalimagestores for offline install
#
# All three use FAMILY=bazzite-full so they share one images.json (all 6
# Bazzite variants in the picker).  The FAMILY setting also controls which
# recipe.json (= default image) is installed; all three use kde-nvidia as
# the picker default.

build_live() {
    local tag="$1" base="$2" family="${3:-bazzite-full}"
    local full_tag="localhost/superiso-live-bazzite-full:${tag}"

    if [[ "${SKIP_CONTAINER_BUILD:-0}" == "1" ]]; then
        if podman image exists "${full_tag}"; then
            echo ">>> Skipping build (SKIP_CONTAINER_BUILD=1): ${full_tag}"
            return 0
        fi
        echo ">>> SKIP_CONTAINER_BUILD=1 but ${full_tag} not in user store; building anyway..."
    fi

    echo ">>> Building live container: ${full_tag} (BASE=${base} FAMILY=${family})"
    podman build \
        --build-arg "BASE_IMAGE=${base}" \
        --build-arg "FAMILY=${family}" \
        --build-arg "INSTALLER_CHANNEL=${INSTALLER_CHANNEL:-stable}" \
        --tag "${full_tag}" \
        --file "${CF}" \
        "${REPO}/live"
    # Image stays in the user's podman store; tacklebox accesses it via
    # rootless podman (podman unshare) without needing sudo podman load.
}

# Pull base images first unless offline mode requested.
if [[ "${SKIP_PULL:-0}" != "1" ]]; then
    echo ">>> Pre-pulling base images..."
    for img in \
        ghcr.io/ublue-os/bazzite-nvidia:stable \
        ghcr.io/ublue-os/bazzite-gnome-nvidia:stable \
        ghcr.io/ublue-os/bazzite-deck:stable; do
        podman pull "${img}"
    done
fi

build_live kde  ghcr.io/ublue-os/bazzite-nvidia:stable
build_live gnome ghcr.io/ublue-os/bazzite-gnome-nvidia:stable
build_live deck  ghcr.io/ublue-os/bazzite-deck:stable

# ── ISO build via tacklebox ───────────────────────────────────────────────────
# tacklebox build --iso will:
#   1. For each bootable_environment: podman image mount → mksquashfs → BLS entry
#   2. For each offline_payload: podman pull --root <scratch> then mksquashfs
#      → LiveOS/store.squashfs.img (the additionalimagestores source)
#   3. Assemble UEFI-bootable ISO9660 via xorriso

echo ">>> Building ISO: ${ISO}"
BUILD_SCRATCH="${OUT}/.tbx-build"
mkdir -p "${BUILD_SCRATCH}"

sudo env "PATH=${PATH}" \
    SUPERISO_COMPRESSION="${SUPERISO_COMPRESSION:-fast}" \
    "${TBX}" build \
    "${REPO}/recipes/bazzite-full.json" \
    --iso "${ISO}" \
    -b "${BUILD_SCRATCH}"

echo ""
echo ">>> Verifying ISO..."
"${TBX}" verify "${ISO}"

# ── Compress ─────────────────────────────────────────────────────────────────
echo ">>> Compressing ${ISO} → ${ISO}.xz (this takes a while)..."
# -k keeps the original; -T0 uses all cores; --fast for quick distributable
# (override with SUPERISO_COMPRESSION=release to use default xz preset)
XZ_OPT="${XZ_OPT:--T0}"
if [[ "${SUPERISO_COMPRESSION:-fast}" == "release" ]]; then
    XZ_OPT="-T0 -9e"
else
    XZ_OPT="-T0 -1"
fi
xz ${XZ_OPT} --keep "${ISO}"

echo ""
echo "=== Build complete ==="
ls -lh "${ISO}" "${ISO}.xz" 2>/dev/null || true
