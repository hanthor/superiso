# Super-ISO — Status & Next Steps

Last updated: 2026-05-11

## TL;DR

We have a working **multi-boot bootc super-ISO** that boots end-to-end in
QEMU/UEFI. Tacklebox multi-env disk media now also boots end-to-end (sd-boot
→ tbox-root → ostree-prepare-root → userspace) for the first time.

- ✅ Build pipeline works end-to-end (stage → live-envs → store-sqfs → iso → disk)
- ✅ Bluefin live env boots to GDM + login prompt under QEMU/UEFI
- ✅ Autologin as `liveuser` works (password "live", NOPASSWD sudo, SSH on tty)
- ✅ Shared-store squashfs loop-mounts at `/var/lib/superiso-store`
- ✅ containers-storage `additionalimagestores` config wires it up so
  `bootc install` can resolve `containers-storage:` refs offline
- ✅ Install backend policy set: SuperISO supports only bootc-installer Flatpak
  and fisherman. Direct `bootc install` is a low-level implementation/debug
  detail, not a user-facing install path.
- ✅ `bootc install` ENOSPC root cause confirmed: `/var/tmp` lived on the
  tiny live root overlay. Manual fix verified in QEMU by mounting a larger
  tmpfs on `/var/tmp`; install completed successfully.
- ✅ Permanent fix added: live env now enables `var-tmp.mount` with a 16 GB
  tmpfs scratch area for offline bootc installs.
- 🚫 GitHub published: <https://github.com/hanthor/superiso>

### 2026-05-11 update — Tacklebox multi-env boot fixed

- ✅ `mkfs.ext4` for `shared_store` now passes `-i 4096` so composefs/ostree
  object stores no longer exhaust inodes (`tacklebox/internal/blockdev/format.go`).
  The 60 GB `examples/all-test.json` recipe (bazzite + aurora + dakota)
  now builds in ~5m20s without ENOSPC.
- ✅ `tbox-root.service` is now ordered correctly relative to
  `ostree-prepare-root.service`. Module-setup symlinks the unit into both
  `initrd-root-fs.target.wants/` *and* `ostree-prepare-root.service.requires/`
  so the ordering edge holds even when ostree-prepare-root is started
  outside the target's transaction. Service also gained
  `StandardOutput=journal+console` for in-QEMU diagnostics.
- ✅ End-to-end QEMU/UEFI boot of a tacklebox-built image: sd-boot menu →
  default entry (aurora alphabetically) → `tbox-root.service` finished →
  `ostree-prepare-root.service` finished → userspace reached.
- ✅ **bootc cross-env collision fixed**: pass
  `--source-imgref containers-storage:<image>` to `bootc install`. Without
  this, bootc's "infer source from running container" heuristic picks the
  wrong image when `/var/lib/containers` is bind-mounted across serial
  installs. With the explicit pin, each install writes its own content.
- ✅ **`tacklebox verify`** ships and catches this exact bug (and any future
  regression) — `2 envs share commit e2c044…: [aurora bazzite]`.

### 2026-05-11 — Tacklebox/SuperISO unification work landed

PLAN-merge.md steps 1-5 done, 6-7 outstanding:

- ✅ Step 1: `internal/target.Target` interface + `BlockTarget` extracted from
  `runBuild()`. Pure refactor, no behavior change.
- ✅ Steps 2-4: `IsoTarget` produces a UEFI-bootable hybrid ISO; live install
  backend (podman image mount + mksquashfs) runs alongside the existing bootc
  flow. `tacklebox build --iso ...` end-to-end booted to a `liveuser` shell
  under QEMU/KVM (`examples/iso-smoke.json`).
- ✅ Step 5: `scripts/profile-to-recipe.sh` converts `profiles/*.tsv` into
  `recipes/*.json` consumable by `tacklebox build --iso`.
- ✅ Step 6: `scripts/build-iso-tbx.sh` and `just iso-tbx <profile>` added to
  wire Tacklebox into the build flow.
- ⏳ Step 7: decide where the recipes live long-term (root `recipes/` vs
  staying in SuperISO as the canonical TSVs).

### 2026-05-11 — Automated Updates & CI Progress

- ✅ **Automated Update System**: `tacklebox update-all` refreshes all envs.
- ✅ **Build-time Provisioning**: `tacklebox build` now drops the updater binary,
  systemd units, and original recipe into every env's filesystem.
- ✅ **`tacklebox status`**: New command to show installed envs, versions, and
  deployment history.
- ✅ **Stage 4 CI (Boot Smoke)**: `scripts/test-boot.sh` added and wired into GHA.
  Boots the built image in QEMU (TCG) and asserts success.

### CI

`tacklebox/.github/workflows/ci.yml` runs on every push/PR:

- `lint-test`: go vet + go test + go build + JSON schema parse + shellcheck
  the dracut module. ~2 min.
- `verify-smoke`: builds a 10 GB two-env block image from
  `centos-bootc:stream10` + `fedora-bootc:42` and runs `tacklebox verify`.
  ~10-15 min, gated on lint-test. Catches regressions in partition layout,
  BLS wiring, and per-env content distinctness.

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

The original **MVP manifest** (`payloads.tsv`) ships:
- **Live env** (bootable from systemd-boot menu): `bluefin`
- **Installer payloads** (selectable in `superiso-install`):
  bluefin, dakota, bazzite, bazzite-nvidia

New profile manifests under `profiles/` target the next build matrix:
- `profiles/dakota.tsv`: Dakota + Dakota-NVIDIA, Dakota-NVIDIA intended live
- `profiles/bluefin.tsv`: Bluefin latest/GTS + DX + NVIDIA variants, NVIDIA live
- `profiles/aurora.tsv`: Aurora + DX + NVIDIA Open variants, NVIDIA Open live
- `profiles/bazzite.tsv`: Bazzite KDE + GNOME + Deck variants, KDE NVIDIA and
  GNOME NVIDIA live roots in one ISO
- `profiles/gold-ublue.tsv`: combined uBlue experiment for one large deduped disk

Implementation direction update:
- Keep the planned **overlay-driver** shared containers-storage. Do not copy
  Dakota/Tromso's VFS payload-store design; VFS explodes for multi-image media.
- Use Dakota/Tromso only as the blueprint for distro-agnostic live boot:
  dmsquash-live initramfs is built in a Debian helper stage, then copied into
  the final image. No base-image package manager and no Fedora livesys scripts.

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

## Offline install scratch-space fix — verified

Original failure:

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

Findings:
- `TMPDIR=/tmp` did **not** help; bootc/ostree-ext still wrote under `/var/tmp`.
- In the live ISO, `/var/tmp` was on the tiny root overlay (~575 MB free).
- Mounting an 8 GB tmpfs on `/var/tmp` made the same offline install succeed.

Verified successful install flow:
- Booted `output/superiso-live.iso` in QEMU/UEFI with a blank 32 GB target disk.
- Mounted tmpfs at `/var/tmp`.
- Ran `bootc install to-disk --source-imgref containers-storage:ghcr.io/ublue-os/bazzite:latest ... --wipe /dev/vda`.
- Result: layers deployed, GRUB installed via bootupd, `Installation complete!`.
- Reboot then reached the installed Bazzite GRUB menu. Full post-boot SSH/status
  check is still pending.

Permanent fix now in repo:
- `live/src/systemd/var-tmp.mount`
- `live/Containerfile.ublue` enables `var-tmp.mount` alongside the shared-store
  mount.

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

## Bootc-installer Flatpak integration

Implemented Dakota/Tromso-style installer integration in the generic live
transform while keeping payload storage overlay/deduped:

- `live/src/install-bootc-installer-flatpak.sh` installs the Tuna/bootc-installer
  Flatpak bundle from the `continuous` release without using the distro package
  manager.
- `scripts/gen-images-json.sh` renders `/etc/bootc-installer/images.json` from
  the profile manifest, so the image picker exactly matches the ISO payloads.
- `scripts/gen-recipe-json.sh` renders `/etc/bootc-installer/recipe.json` with
  matching profile branding and `local_imgref=containers-storage:<default>`.
- `scripts/gen-installer-assets.sh` generates simple SVG brand assets for the
  installer/tour and per-image picker icons.
- `live/Containerfile.generic` now copies the generated config/assets, touches
  `/etc/bootc-installer/live-iso-mode`, autostarts the installer in GNOME/KDE,
  links `fisherman`, and installs polkit rules for passwordless live installs.

Validation performed against Dakota live image:
- `org.bootcinstaller.Installer` is present in system Flatpaks.
- `images.json` lists Dakota + Dakota-NVIDIA with host-visible SVG icons.
- `recipe.json` says `Dakota SuperISO` and uses
  `containers-storage:ghcr.io/projectbluefin/dakota-nvidia:latest`.
- `/etc/xdg/autostart/superiso-installer.desktop` launches the Flatpak with
  `VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json`.
- `/usr/local/bin/fisherman` symlink exists.

Note: the four smoke-tested ISOs listed above were built before this Flatpak
integration landed. Re-run `live-envs iso` per profile (store can be reused) to
produce GUI-installer-enabled ISOs.

## Roadmap

### Step 1 — Verify install (current blocker)
- [x] Add `liveuser` autologin + SSH to live env
- [x] Verify SSH-into-VM works
- [x] Verify shared-store mount + additionalimagestores
- [x] **Make fisherman install succeed end-to-end from live → target disk**
- [ ] Reboot the install VM into the target disk and confirm `bootc status`

### Step 2 — profile build matrix
Build four independent profile ISOs in parallel:
- [x] `just profile dakota` → Dakota + Dakota-NVIDIA, intended NVIDIA live
- [x] `just profile aurora` → Aurora + DX + NVIDIA Open, NVIDIA Open live
- [x] `just profile bluefin` → Bluefin latest/GTS + DX + NVIDIA, NVIDIA live
- [x] `just profile bazzite` → Bazzite KDE + GNOME + Deck; two NVIDIA live roots

Current successful build artifacts under `/var/tmp/superiso-output/`:

| Profile | ISO | Shared store | Live roots | Smoke test |
|---|---:|---:|---|---|
| Dakota | 6.7 GB | 3.4 GB | `dakota-nvidia` | ✅ boot + SSH + store |
| Aurora | 12 GB | 6.9 GB | `aurora-nvidia-open` | ✅ boot + SSH + store |
| Bazzite | 22 GB | 13 GB | `bazzite-kde-nvidia`, `bazzite-gnome-nvidia` | ✅ boot + SSH + store |
| Bluefin | 22 GB | 18 GB | `bluefin-nvidia` | ✅ boot + SSH + store |

Smoke tests verified:
- live ISO reaches userspace and SSH (`liveuser:live`)
- `/var/tmp` is a 16 GB tmpfs
- `/var/lib/superiso-store` mounts from `/LiveOS/store.squashfs.img`
- every profile's offline installer images are visible via `sudo podman images`

Detailed image inventory and size comparison is in `ISO-INVENTORY.md`.

Parallel driver:
```fish
SUPERISO_PROFILE_JOBS=4 just profiles
```

Bazzite can also be split if desired:
```fish
just profile bazzite-kde
just profile bazzite-gnome
```

### Step 3 — going-for-gold uBlue disk
- [ ] `just gold` builds `profiles/gold-ublue.tsv` into `output/gold-ublue/`.
- [ ] Size-test the shared `store.sfs` to decide whether Dakota should merge into
      the gold disk or stay separate.

### Step 4 — distro-agnostic live transform
- [x] Confirmed Dakota-NVIDIA cannot run the old uBlue transform (`dnf` missing).
- [x] Added `live/Containerfile.generic`: Debian helper stage builds
      dmsquash-live initramfs against the base image kernel modules; final stage
      does not use the base package manager and does not install livesys scripts.
- [x] Re-run Dakota, Aurora, Bluefin, and Bazzite profiles with the generic
      transform and verify each live session boots.

### Step 4 — Polish
- [ ] Fix `just disk` partition layout: parted prunes the ISO9660
      partition entry. The ISO9660 fs bytes survive but tools that
      enumerate via the partition table may not see it — research
      whether to keep a hybrid xorriso layout intact or migrate to a
      pure GPT layout with the live data on its own ext4/squashfs
      partition.
- [x] Hook up the bootc-installer Flatpak and fisherman backend in
      `Containerfile.generic`. `superiso-install` is now only a headless
      fisherman wrapper, not a direct bootc installer.
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
4. **fisherman is the supported SuperISO installer backend.**
   Direct bootc install may need scratch outside containers-storage, but
   fisherman handles live-media scratch correctly by using the target disk.
5. **Host `/tmp` was a 48 GB tmpfs that overflowed** with serial logs +
   QEMU disk images, breaking shell forks at the system level. Always
   put large QEMU images on `/var/tmp` (not `/tmp`) and rotate logs.

### 2026-05-12 — End-to-end install test from Bazzite Full ISO

- ✅ ISO boots in QEMU/UEFI — all 3 live envs in sd-boot menu
- ✅ All 6 Bazzite variants visible via `sudo podman images` (offline store)
- ✅ bootc-installer Flatpak present, fisherman symlinked
- ✅ `var-tmp.mount` 16 GiB tmpfs for installer scratch
- ✅ Bazzite KDE (AMD/Intel) installed offline → SSH'd into running system
  - OS: Bazzite 44.20260511.0 (Kinoite), kernel 6.19.14-ogc2.1.fc44.x86_64
  - bootc deployment: ghcr.io/ublue-os/bazzite:stable @ sha256:e27048d3...
  - No network access required during install

**GRUB + btrfs block-group-tree**: GRUB 2.12 can read btrfs (it found the
BLS entries) but refuses to load the kernel when the filesystem has the
`compat_ro` block-group-tree feature (0x400, default in btrfs-progs 6.19+).
`bootc install to-disk --filesystem btrfs` puts `/boot` on the btrfs root
partition, so GRUB must read btrfs to load vmlinuz → fails.
Fisherman's layout (separate 1 GiB ext4 `/boot` + btrfs `/`) avoids this
entirely: GRUB reads ext4 `/boot`, never touches btrfs.
→ **Use `--filesystem ext4` with `bootc install to-disk` until GRUB gains
BGT support** (no upstream patch merged as of 2026-05-12), OR use fisherman
which creates the correct layout automatically.
