# Super-ISO

A bootable ISO/disk image that **bundles multiple bootc images as
independently-bootable live environments** with a shared installer.  Boot any
family from a single USB; install any of the embedded images offline.

```
+-------------------------------------------------------------------+
|  systemd-boot menu                                                |
|    1. Bazzite NVIDIA Live   (live=bazzite-nvidia)                 |
|    2. Bluefin NVIDIA Live   (live=bluefin-nvidia)                 |
|    3. Aurora NVIDIA Live    (live=aurora-nvidia)                  |
|    4. Dakota Live           (live=dakota)                         |
|                                                                   |
|  Each live env mounts the SHARED store at /var/lib/containers     |
|  /storage and runs `superiso-install` (or the bootc-installer     |
|  flatpak), which lets you install ANY of the 7 embedded images:   |
|    bazzite | bazzite-nvidia | bluefin | bluefin-nvidia            |
|    aurora  | aurora-nvidia  | dakota                              |
|                                                                   |
|  Persistence partition (LABEL=SUPERISOPST) is shared across all   |
|  live envs — overlay'd onto the rootfs by dmsquash-live.          |
+-------------------------------------------------------------------+
```

NVIDIA variants are the live entries so the desktop works on NVIDIA
hardware out of the box.  Non-NVIDIA users still get a working desktop
(the kernel module just doesn't load) and can install the non-NVIDIA
variant from the installer picker.  The installer pre-selects the
*family* you booted (boot bazzite-nvidia → bazzite is highlighted).

## Status: v0 multi-boot scaffold

Working:
- TSV-driven payload manifest with `family` + `live` columns
- Multi-image staging into a shared overlay-driver containers-storage
- Per-family live env build (`Containerfile.ublue` + `Containerfile.dakota`)
- Per-family rootfs squashfs (no embedded store — keeps each ~3 GB)
- Shared store squashfs (loop-mounted at boot via `superiso-store.mount`)
- Multi-boot UEFI/systemd-boot ISO (one menu entry per live family)
- Persistence partition wrapper (`just disk`) with ext4 `SUPERISOPST`
- Per-family installer config (`images.<family>.json`) with default-family
  preselection
- Minimal CLI installer (`/usr/local/bin/superiso-install`) as a fallback
  before the bootc-installer flatpak is integrated

Deferred:
- bootc-installer flatpak GUI integration (your separate project)
- Image signature verification via `containers-policy.json`
- Online image refresh from the live env (pull new versions onto persistence
  partition, layer onto containers-storage at boot)
- composefs storage backend (still experimental in bootc)

## Build

Prereqs (host):
- `podman`, `just`, `jq`
- `xorriso`, `mkfs.fat`, `mtools`, `mksquashfs`, `sgdisk`, `losetup`
- A checkout of [dakota-iso](https://github.com/projectbluefin/dakota-iso)
  next to this repo (only used for the dakota live env's pre-built
  initramfs)
- ~80 GB free on the build filesystem (release-compression target ~25 GB ISO,
  but the working set incl. overlay containers-storage is much larger)

```fish
# 0. (one-time) Build the dakota live base.  ~30 minutes.
just dakota-base

# 1. Edit payloads.tsv to choose what ships.

# 2. End-to-end build.
just all                         # = stage → live-envs → store-sqfs → iso

# Faster iteration:
just stage                       # pull/refresh containers-storage
just live-envs                   # rebuild every live env (sequential)
just store-sqfs                  # squashfs the shared store
just iso                         # multi-boot ISO assembly
just disk persist_mb=16384       # wrap into raw .img with 16 GB persistence

# Use release compression on a final build:
just compression=release all
```

Flash to USB:
```fish
sudo dd if=output/superiso.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Boot in QEMU for testing:
```fish
just boot       # serial console on stdout, target disk at /dev/vda
```

## How dedup works

1. **Layer-level (highest impact)**: the `overlay` containers-storage driver
   stores each layer once on disk keyed by digest.  bazzite, bazzite-nvidia,
   bluefin all share the ublue base layers natively — those layers exist
   exactly once in `output/cs-staging/var/lib/containers/storage/overlay`,
   and once in the resulting `store.sfs`.
2. **Block-level**: mksquashfs `-dedup` (default in zstd mode) catches
   identical blocks within each squashfs.
3. **Live env footprint**: each per-family rootfs squashfs *omits* the
   `/var/lib/containers/storage` payload — the store is loop-mounted at boot
   via `superiso-store.mount`.  This keeps each rootfs squashfs ~3 GB
   regardless of how many payloads you embed.

## Layout

```
superiso/
  payloads.tsv                       source of truth for embedded images
  justfile                           orchestration
  scripts/
    gen-images-json.sh               TSV → bootc-installer config (per family)
    stage-payloads.sh                pull every ref into shared overlay store
    build-live-env.sh                per-family live container + extract artefacts
    build-store-sqfs.sh              squashfs the shared containers-storage
    build-iso.sh                     multi-boot UEFI ISO assembly
    build-disk.sh                    ISO → hybrid raw .img with persistence partition
  live/
    Containerfile.ublue              generic Fedora-bootc → live transform
    Containerfile.dakota             dakota → live transform (FROM dakota-installer)
    src/
      systemd/superiso-store.mount   loop-mount store.squashfs.img at boot
      superiso-install               minimal TUI installer
      etc/bootc-installer/
        images.<family>.json         generated; gitignored
  output/
    cs-staging/                      shared containers-storage (overlay driver)
    live/<family>/                   per-family build artefacts
      vmlinuz initramfs.img rootfs.sfs EFI/
    store.sfs                        shared store squashfs (loop-mounted at boot)
    superiso-live.iso                final multi-boot ISO
    superiso.img                     hybrid disk image with persistence partition
  plan.md                            design doc
```

## Boot flow

```
UEFI firmware
  → ESP/EFI/efi.img (FAT)
    → systemd-boot → loader/loader.conf → loader/entries/<family>.conf
      → kernel + initrd from /images/pxeboot/<family>/
        → dmsquash-live initramfs:
            root=live:CDLABEL=SUPERISO
            rd.live.dir=LiveOS
            rd.live.squashimg=<family>.rootfs.sfs
            rd.live.overlay=LABEL=SUPERISOPST   (persistence)
            rd.live.overlay.overlayfs=1
            superiso.family=<family>
          → mounts <family>.rootfs.sfs as the live root
          → systemd brings up var-lib-containers-storage.mount
            which loop-mounts /run/initramfs/live/LiveOS/store.squashfs.img
            at /var/lib/containers/storage
          → desktop session
          → installer reads /etc/bootc-installer/images.json
            (default_family = booted family) and runs:
              bootc install to-disk \
                --source-imgref containers-storage:<chosen-ref> \
                --target-imgref docker://<chosen-ref> \
                /dev/<target>
```
