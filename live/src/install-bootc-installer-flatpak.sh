#!/usr/bin/bash
# Install the bootc-installer/tuna-installer Flatpak bundle into the live image.
# Distro-agnostic: assumes the base desktop image already ships flatpak, curl,
# and dbus-daemon.  Does not use a package manager.

set -exo pipefail

command -v flatpak >/dev/null || { echo "flatpak missing in base image" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl missing in base image" >&2; exit 1; }
command -v dbus-daemon >/dev/null || { echo "dbus-daemon missing in base image" >&2; exit 1; }

FLATPAK_CACHE="/var/cache/flatpak-dl"
mkdir -p "${FLATPAK_CACHE}/tmp" /run/dbus /var/lib/flatpak/repo
export TMPDIR="${FLATPAK_CACHE}/tmp"

dbus-daemon --system --fork --nopidfile || true
sleep 1

if [ -d "${FLATPAK_CACHE}/repo/refs" ]; then
    echo "Seeding flatpak repo from build cache..."
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --ignore-existing "${FLATPAK_CACHE}/repo/" /var/lib/flatpak/repo/ || true
    else
        cp -a -n "${FLATPAK_CACHE}/repo/." /var/lib/flatpak/repo/ || true
    fi
fi

# Initializes /var/lib/flatpak/repo on images where flatpak is installed but
# no system repo has been created yet.
if [ ! -d /var/lib/flatpak/repo/objects ]; then
    command -v ostree >/dev/null || { echo "ostree missing; cannot initialize flatpak repo" >&2; exit 1; }
    ostree init --repo=/var/lib/flatpak/repo --mode=bare-user-only
fi
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

RELEASE_TAG="continuous"
FLATPAK_FILENAME="org.bootcinstaller.Installer.flatpak"
INSTALLER_APP_ID="org.bootcinstaller.Installer"
if [[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]]; then
    RELEASE_TAG="continuous-dev"
    FLATPAK_FILENAME="org.bootcinstaller.Installer.Devel.flatpak"
    INSTALLER_APP_ID="org.bootcinstaller.Installer.Devel"
fi

curl --retry 3 --location \
    "https://github.com/tuna-os/tuna-installer/releases/download/${RELEASE_TAG}/${FLATPAK_FILENAME}" \
    -o /tmp/bootc-installer.flatpak

flatpak install --system --noninteractive --bundle /tmp/bootc-installer.flatpak || \
    flatpak update --system --noninteractive "${INSTALLER_APP_ID}"
rm -f /tmp/bootc-installer.flatpak

# Make host config/branding visible to the sandbox.
flatpak override --system --filesystem=/etc:ro "${INSTALLER_APP_ID}" || true
flatpak override --system --filesystem=/usr/share/bootc-installer:ro "${INSTALLER_APP_ID}" || true

mkdir -p "${FLATPAK_CACHE}"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete /var/lib/flatpak/repo/ "${FLATPAK_CACHE}/repo/" || true
else
    rm -rf "${FLATPAK_CACHE}/repo"
    mkdir -p "${FLATPAK_CACHE}/repo"
    cp -a /var/lib/flatpak/repo/. "${FLATPAK_CACHE}/repo/" || true
fi

echo "Installed ${INSTALLER_APP_ID}"
