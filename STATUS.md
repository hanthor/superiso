# Super-ISO — Status & Next Steps

Last updated: 2026-05-08

## TL;DR

We have a working **multi-boot bootc super-ISO** that boots end-to-end in
QEMU/UEFI. One blocker remains for offline install: bootc's layer-extract
step needs more scratch space than the live tmpfs provides.

- ✅ Build pipeline works end-to-end (stage → live-envs → store-sqfs → iso → disk)
- ✅ Bluefin live env boots to GDM + login prompt under QEMU/UEFI
- ✅ Autologin as `liveuser` works (password "live", NOPASSWD sudo, SSH on tty)
- ✅ Shared-store squashfs loop-mounts at `/var/lib/superiso-store`
- ✅ containers-storage `additionalimagestores` config wires it up so
  `bootc install` can resolve `containers-storage:` refs offline
- ⚠️ `bootc install` fails with **"no space left on device"** on `/var/tmp`
  while extracting layers (4.9 GB of layers, tmpfs is too small)
- 🚫 GitHub published: <https://github.com/hanthor/superiso>

## What's in the repo right now

```
hanthor/superiso  (public)  main: d576e82
  payloads.tsv
  justfile
  scripts/
    gen-images-json.sh    stage-payloads.sh    build-live-env.sh
    build-store-sqfs.sh   build-iso.sh         build-disk.sh
  live/
    Containerfile.ublue
    src/
      systemd/superiso-store.mount
      superiso-install
  README.md  plan.md  STATUS.md  .gitignore
```

The **MVP manifest** (`payloads.tsv`) currently ships:
- **Live env** (bootable from systemd-boot menu): `bluefin`
- **Installer payloads** (selectable in `superiso-install`):
  bluefin, dakota, bazzite, bazzite-nvidia

## Boot architecture — verified working

```
UEFI firmware
  → systemd-boot (in ESP at /EFI/efi.img)
    → loader/loader.conf (default = bluefin.conf, timeout 5)
    → loader/entries/bluefin.conf  (ephemeral)
    → loader/entries/bluefin-persist.conf  (uses LABEL=SUPERISOPST)
  → kernel + dracut initramfs (with dmsquash-live)
    → finds /dev/disk/by-label/SUPERISO
    → mounts /run/initramfs/live  (the ISO9660)
    → losetup /dev/loop0 = bluefin.rootfs.sfs
    → mount squashfs at /run/initramfs/squashfs
    → overlayfs(tmpfs) for writable layer
    → switch_root /sysroot
  → systemd userspace
    → var-lib-superiso\x2dstore.mount loop-mounts store.squashfs.img
      at /var/lib/superiso-store (read-only)
    → /etc/containers/storage.conf registers it as additionalimagestore
    → gdm.service starts, agetty autologins liveuser on ttyS0/tty1
    → motd: "Super-ISO live (bluefin family) — Run `superiso-install`..."
```

## The one remaining blocker

```
$ sudo bootc install to-disk \
    --source-imgref containers-storage:ghcr.io/ublue-os/bazzite:latest \
    --target-imgref docker://ghcr.io/ublue-os/bazzite:latest \
    --filesystem btrfs --wipe /dev/vda

… partitions+filesystems created OK …
Initializing ostree layout
layers already present: 0; layers needed: 128 (4.9 GB)
error: ... GetBlob: write /var/tmp/container_images_824836045:
       no space left on device
```

bootc/ostree's container-import path stages layers under `/var/tmp` while
building the ostree commit, even when the source is already in
containers-storage on local disk. On a 16 GB QEMU VM the tmpfs `/var/tmp`
seems still too small for the 4.9 GB extract — possibly because half-RAM
default + page cache holds it back.

### Three fix options to try, in order of simplicity

1. **Set `TMPDIR` to a path on the freshly-formatted target btrfs.**
   bootc creates `/dev/vda3` and mounts it during install — if we can
   make ostree-ext use that as scratch, it has 31 GB available. Try:
   ```fish
   sudo TMPDIR=/run/install/dest bootc install to-disk ...
   ```
   The exact mount path during install needs verification (`mount` while
   install is paused, or read bootc source `crates/lib/src/install.rs`).

2. **Make `/var/tmp` larger in the live env.** Either:
   - Mount tmpfs at `/var/tmp` with `size=8G` via a systemd unit in the
     live env (default tmpfs = half RAM, but `/var/tmp` may be on the
     overlay rootfs which is small).
   - Or bind-mount a portion of the persistence partition (when present)
     onto `/var/tmp`.

3. **Skip the staging copy entirely.** Investigate whether
   `bootc install --source-imgref ostree-unverified-image:...` or a
   different transport bypasses the `/var/tmp` extract step. Check
   `bootc install --help` flags like `--composefs-native`,
   `--via-loopback`, or env vars like `BOOTC_DIRECT_LAYER_COPY`.

## What to do after rebooting

The host filesystem is tight (`/var` 97% full, `/tmp` was 82%) — that's
why the shell stopped working. After reboot:

1. **Free more disk** if needed:
   ```fish
   # Already deleted these once; if they reappeared:
   sudo rm -rf /var/tmp/ubuntu-26.04-* /var/tmp/bootable.raw \
              /var/tmp/podman* /var/tmp/container_images_* \
              /var/tmp/buildah-cache-*
   ```
2. **Resume from a known-good state** — the last good build artefacts are
   on disk in `output/`:
   ```
   output/superiso-live.iso       # 14 GB, bootable, MVP
   output/superiso.img            # 27 GB, hybrid raw with persistence
   output/live/bluefin/{vmlinuz,initramfs.img,rootfs.sfs,EFI/}
   output/store.sfs               # 10 GB, shared containers-storage
   output/cs-staging/             # 36 GB raw layer storage
   ```
3. **Continue install verification**:
   ```fish
   cd /var/home/james/dev/superiso
   # Boot the ISO with 16 GB RAM (or more):
   sudo /usr/libexec/qemu-kvm -machine q35 -m 16384 -smp 4 \
     -accel kvm -cpu host \
     -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
     -drive if=pflash,format=raw,file=/tmp/sup-vars.fd \
     -drive if=none,id=iso,file=output/superiso-live.iso,media=cdrom,readonly=on,format=raw \
     -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=iso \
     -drive if=virtio,format=qcow2,file=/tmp/target.qcow2 \
     -netdev user,id=net0,hostfwd=tcp::3322-:22 \
     -device virtio-net-pci,netdev=net0 \
     -serial mon:stdio -display none

   # Then SSH in and apply one of the three fix options above:
   sshpass -p live ssh -p 3322 liveuser@127.0.0.1
   ```

## Roadmap (was planned next, now blocked on /var space)

### Step 1 — Verify install (current blocker)
- [x] Add `liveuser` autologin + SSH to live env
- [x] Verify SSH-into-VM works
- [x] Verify shared-store mount + additionalimagestores
- [ ] **Make `bootc install` succeed end-to-end from live → target disk**
- [ ] Reboot the install VM into the target disk and confirm `bootc status`

### Step 2 — ublue tri-family super-ISO
Manifest: bluefin-nvidia + bazzite-nvidia + aurora-nvidia as **live**;
all 12+ ublue variants (gnome/kde × dx × nvidia) as installer payloads.
- [ ] Pull the missing nvidia variants via `just stage` (network: ~30 GB)
- [ ] Add a `liveuser` autologin to all three live envs (already in
      `Containerfile.ublue`, just needs to be `live=true` in TSV)
- [ ] `just compression=release all` → ~28 GB ISO

### Step 3 — Dakota duo super-ISO
Manifest: dakota + dakota-nvidia as **live**; just those two as
installer payloads.
- [ ] Adapt dakota-iso's three-stage Containerfile pattern into a
      self-contained `Containerfile.dakota` (FROM ghcr.io/projectbluefin
      directly + Debian builder for dracut/dmsquash-live, no
      `localhost/dakota-installer` dependency)
- [ ] Build & test
- [ ] Either separate ISO or merge dakota into the ublue ISO if size
      and partition layout allow

### Step 4 — Polish
- [ ] Fix `just disk` partition layout: parted prunes the ISO9660
      partition entry. The ISO9660 fs bytes survive but tools that
      enumerate via the partition table may not see it — research
      whether to keep a hybrid xorriso layout intact or migrate to a
      pure GPT layout with the live data on its own ext4/squashfs
      partition.
- [ ] Hook up the bootc-installer flatpak (your separate project) by
      shipping it preinstalled in `Containerfile.ublue` — currently the
      live env falls back to the small TUI `superiso-install` script.
- [ ] First-boot service: grow the `SUPERISOPST` partition to fill the
      USB on first boot (sgdisk/parted + resize2fs).
- [ ] Signature verification of embedded images via
      `containers-policy.json` — set `transports.containers-storage.<ref> =
      { type: "signedBy", … }` once we have a signing story.

## Disk budget reminders

For each variant of an ISO, plan for:
- ~12–16 GB final ISO (4 ublue families, fast compression)
- ~25 GB working set (cs-staging) preserved between runs
- ~6–8 GB per live-env build (rootfs squashfs)
- ~25–35 GB peak during `just disk` (writes a new image alongside ISO)

Target `output_dir` should live on a filesystem with **≥ 80 GB free** for
a clean run from scratch. The shared `output/cs-staging/` is reusable
across runs — don't delete it.

## Lessons learned (so we don't repeat)

1. **Don't depend on local pre-built images** — initial design coupled
   us to `localhost/dakota-installer`. Its initramfs turned out to be
   the bootc/ostree initramfs, not the dmsquash-live one we needed.
   Fixed by moving to `dnf install dracut-live + systemd-boot-unsigned`
   in `Containerfile.ublue`, building everything from upstream ghcr.io.
2. **`rd.live.overlay=LABEL=...` blocks at boot if the partition is
   missing** (interactive plymouth prompt). We split into two loader
   entries per family: `<fam>.conf` (tmpfs overlay) and
   `<fam>-persist.conf` (with rd.live.overlay=).
3. **parted's `mkpart` on an ISO-laid hybrid GPT prunes the ISO9660
   partition entry.** The bytes still live on disk and ISO9660 still
   boots, but `lsblk`/`losetup -P` won't expose the ISO region as a
   separate partition. Ordering by **start sector** (not partition
   number) when picking which one to format is critical — otherwise you
   nuke the ESP. (Bug found and fixed in `build-disk.sh`.)
4. **bootc install needs scratch space outside containers-storage.**
   Even with `--source-imgref containers-storage:`, ostree-ext stages
   layers under `/var/tmp`. Plan for ≥ 6 GB of writable scratch in the
   live env or pass `TMPDIR=`.
5. **Host `/tmp` was a 48 GB tmpfs that overflowed** with serial logs +
   QEMU disk images, breaking shell forks at the system level. Always
   put large QEMU images on `/var/tmp` (not `/tmp`) and rotate logs.
