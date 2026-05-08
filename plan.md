# Super-ISO: Multi-Image bootc Live + Installer USB

## Context

A single large bootable USB image that:

1. Embeds **many bootc images** on one device.
2. Lets the user **boot any one of N live envs** (NVIDIA variants by default
   so the live desktop works on NVIDIA hardware).
3. Lets the user **install any of the 7 embedded images** offline from any
   live env via the bootc-installer flatpak (or the CLI fallback).
4. **Deduplicates** so the bazzite + bazzite-nvidia + bluefin + aurora set
   doesn't quadruple the size.
5. Provides a **persistent partition** for `/home`, user files, and extra
   images — the USB doubles as a portable workstation.

The installer in each live env pre-selects the **family** that was booted
(boot bazzite-nvidia → bazzite is highlighted, with nvidia preferred).

## What exists today (key findings from exploration)

- **dakota-iso** (`/var/home/james/dev/dakota-iso/justfile:218-309`) and **tromso-iso** both build a custom ISO with `mksquashfs -dedup` on a staging tree containing `/var/lib/containers/storage`. Dakota does `buildah commit --squash` (justfile:236) to collapse layers and avoid VFS-driver explosion (~120 layers × 6 GB).
- **bootc-isos** uses `image-builder-cli` with `--bootc-installer-payload-ref` — but only **one** payload per ISO (`/var/home/james/dev/bootc-isos/justfile`, `image-builder-cli/cmd/image-builder/main.go`).
- **`bootc install --source-imgref containers-storage:<ref>`** is fully supported (`/var/home/james/dev/bootc/crates/lib/src/install.rs:300-308, 1549-1584, 843-846`). This is the offline-install primitive we need.
- **Experimental unified storage** (`/var/home/james/dev/bootc/docs/src/experimental-unified-storage.md`) holds multiple images in `/usr/lib/bootc/storage`, but reflink support in containers/image is missing — relevant for the *installed* system, not for our embedded payload.
- **Composefs backend** (`docs/src/experimental-composefs.md`) is experimental and not required for v1.
- **bcvk** is for VM testing only — not a build tool.
- **Dakota already encodes multi-image intent** at `dakota/src/etc/bootc-installer/images.json` — schema is the right hook to extend.

## Approach

Fork dakota-iso's build pipeline and extend it for **multi-bootable**:

1. Per-family live env: each `live=true` row in `payloads.tsv` is built into
   its own (kernel, dmsquash-live initramfs, rootfs squashfs) triple.
2. Shared **overlay-driver containers-storage** at `output/cs-staging` —
   layer-level dedup across all 7 payloads.
3. Shared store **squashfs** (`store.sfs`) loop-mounted at
   `/var/lib/containers/storage` by a systemd unit in every live env, so
   the ~12 GB store appears once on the ISO, not 4×.
4. Multi-entry **systemd-boot** menu — one entry per `live=true` family.
5. Optional hybrid raw `.img` with a writable **persistence partition**
   (LABEL=`SUPERISOPST`) added by `scripts/build-disk.sh`.
6. Per-family `images.<family>.json` with `default_family` so the installer
   picker pre-selects the booted family.

### Disk layout

GPT, written to USB with `dd`:

| # | Type | Size | Contents |
|---|------|------|----------|
| 1 | EFI System (FAT32) | 512 MB | systemd-boot, kernel, initramfs, El Torito for ISO9660 hybrid boot |
| 2 | Linux (squashfs) | sized to fit | `rootfs.sqfs` — live OS + `/var/lib/containers/storage` with all embedded images |
| 3 | Linux (ext4, label `superiso-persist`) | rest of USB (resized on first boot to fill device) | `/home`, downloaded extra images, user state |

dmsquash-live overlay binds persistence partition over the read-only squashfs.

### Build pipeline (new repo `superiso/`)

```
superiso/
  justfile                    # orchestration (modeled on dakota-iso/justfile)
  live/
    Containerfile             # minimal live env: kernel, dracut, systemd-boot, bootc-installer flatpak
    src/etc/bootc-installer/images.json   # lists N embedded images
    src/build-disk.sh         # assembles squashfs + raw disk image
  payloads.toml               # list of (oci-ref, label, icon) tuples to embed
  output/
```

`payloads.toml` example:

```toml
[[image]]
ref = "ghcr.io/ublue-os/bazzite:latest"
label = "Bazzite (GNOME, AMD/Intel)"

[[image]]
ref = "ghcr.io/ublue-os/bazzite-nvidia:latest"
label = "Bazzite (GNOME, NVIDIA)"

[[image]]
ref = "ghcr.io/ublue-os/bluefin:latest"
label = "Bluefin (GNOME)"

[[image]]
ref = "ghcr.io/ublue-os/aurora:latest"
label = "Aurora (KDE)"
```

### Build steps (just recipes, modeled on `dakota-iso/justfile:218-309`)

1. `just live` — build the live container (Containerfile under `live/`). Reuse dakota's three-stage pattern (`dakota/Containerfile:1-96`) but trim to a minimal GNOME-or-KDE shell that hosts the bootc-installer flatpak.
2. `just stage-payloads` — for each entry in `payloads.toml`:
   - `skopeo copy docker://<ref> containers-storage:[overlay@${CS_STAGING}/var/lib/containers/storage+${RUN}]<ref>`
   - **Do not** `buildah commit --squash` per-image — squashing wins on VFS but loses cross-image layer sharing. With overlay driver, unsquashed layers dedupe naturally because identical layer digests are stored once.
   - Generate `images.json` from `payloads.toml`.
3. `just sqfs` — `mksquashfs ${LIVE_ROOT} rootfs.sqfs -comp zstd -Xcompression-level 15 -b 1M -no-duplicates=false` (mirroring `dakota-iso/justfile:306-309` but keep dedup on, which is the default).
4. `just disk` — build raw disk image:
   - `truncate` to target size
   - `sgdisk` GPT with three partitions
   - `mkfs.fat` ESP, copy systemd-boot + kernel + initramfs
   - `dd` rootfs.sqfs into partition 2
   - `mkfs.ext4 -L superiso-persist` partition 3 (small initial; first-boot service grows it)
5. `just hybrid-iso` (optional) — wrap with `xorriso` for hybrid CD/USB boot, like `dakota/src/build-iso.sh:1-208`.

### Live env → installer flow

- systemd-boot → kernel → dracut `dmsquash-live` → live root from partition 2 with overlay on partition 3.
- A `superiso-firstboot.service` resizes partition 3 to fill the device, creates `/home` directories.
- Live desktop autostarts the **bootc-installer flatpak** (your separate project; the super-ISO just provides the inputs).
- Installer reads `/etc/bootc-installer/images.json`, presents picker.
- On selection: `pkexec bootc install to-disk --source-imgref containers-storage:<ref> --target-imgref docker://<ref> /dev/<target>`.
- `containers-storage:` transport pulls from `/var/lib/containers/storage` (offline). bootc handles writing ostree commits to the target disk normally.

### Why this dedupes well

- **Layer-level**: identical layer digests across bazzite/bazzite-nvidia/bluefin (Fedora base, ublue base) are stored once by overlay driver.
- **Block-level**: mksquashfs `-dedup` (default in zstd mode) catches identical 1 MB blocks even where layer digests differ slightly.
- **Empirical expectation**: 4 ublue images at ~6 GB each = 24 GB raw; expect 10–14 GB squashed (similar ratio to dakota's single-image build at ~22 GB working set per `dakota-iso/README.md:42`).

## Critical files to create / model on existing ones

| New file | Modeled on |
|---|---|
| `superiso/justfile` | `/var/home/james/dev/dakota-iso/justfile` (especially lines 218-309) |
| `superiso/live/Containerfile` | `/var/home/james/dev/dakota-iso/dakota/Containerfile:1-96` |
| `superiso/live/src/build-disk.sh` | `/var/home/james/dev/dakota-iso/dakota/src/build-iso.sh:1-208` |
| `superiso/live/src/etc/bootc-installer/images.json` | `/var/home/james/dev/dakota-iso/dakota/src/etc/bootc-installer/images.json` (extend to array) |
| `superiso/payloads.toml` | new |

## Verification

1. **Build smoke test**: `just live && just stage-payloads && just sqfs` produces `output/rootfs.sqfs`. Inspect with `unsquashfs -ll | grep containers/storage` to confirm all image refs present.
2. **Size check**: `ls -lh output/rootfs.sqfs` < sum of input image sizes — confirms dedup.
3. **VM boot test** with bcvk (`/var/home/james/dev/bootc/bcvk.just`):
   ```
   bcvk ephemeral --disk output/superiso.img --memory 8G --efi
   ```
   Verify live desktop boots, installer flatpak launches, all images visible.
4. **Offline install test**: Disconnect VM network. From live env, run `bootc install to-disk --source-imgref containers-storage:ghcr.io/ublue-os/bazzite:latest /dev/vdb`. Reboot from `/dev/vdb`. Verify `bootc status` shows the right image.
5. **Persistence test**: Write a file to `/home/user/test.txt` in live env. Reboot from USB. Confirm file persists.
6. **USB write test**: `dd if=output/superiso.img of=/dev/sdX bs=4M status=progress`, boot real hardware.

## Out of scope for v1

- Composefs storage backend (still experimental in bootc).
- bootc-installer flatpak itself — assumed to exist as a separate project; super-ISO just provides `images.json` and the embedded storage.
- Signature verification of embedded images (add later via `containers-policy.json`).
- Image *update* of embedded payloads from the live env (could be added: pull to persistence partition, layer onto containers-storage at boot).
