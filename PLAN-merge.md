# Plan: Merge SuperISO into Tacklebox

**Status:** Proposed, not started.
**Last updated:** 2026-05-11.

## Why

SuperISO and tacklebox solve the same problem twice:

| Concern               | SuperISO (`scripts/build-*.sh`)                 | Tacklebox (`tacklebox build`)                       |
| --------------------- | ----------------------------------------------- | --------------------------------------------------- |
| Multi-env layout      | systemd-boot + per-family BLS entries           | systemd-boot + per-env BLS entries                  |
| Per-env content       | Live squashfs (`dmsquash-live`, `rd.live.*`)    | bootc install + ostree deployment per env           |
| Output                | ISO9660 / El Torito                             | Loop image or `/dev/*` block device                 |
| Persistence           | Optional overlayfs partition                    | `TBOX_PERSIST` ext4 partition + dracut overlay      |
| Recipe                | TSV per profile + Containerfile.generic         | JSON recipe + Containerfile.generic (same one)      |
| Live-env transform    | `live/Containerfile.generic`                    | (uses the same; tacklebox just consumes the result) |

The shared pieces (Containerfile, dracut module, profile concept) are
already de-duplicated via the `live/src/dracut/95tbox-root` sync committed
on 2026-05-11. The remaining duplication is in *output assembly*: SuperISO
glues things into an ISO, tacklebox glues them onto a block device.

## End state

One CLI: `tacklebox`. Three output target types:

1. **`tacklebox build recipe.json /dev/sdX`** — provision a real disk
   (today; unchanged).
2. **`tacklebox build recipe.json image.img`** — sparse loop image
   (today; unchanged).
3. **`tacklebox build recipe.json --iso super.iso`** — emit a
   UEFI-bootable ISO9660 (new; replaces SuperISO's `scripts/build-iso.sh`).

The recipe schema gains a top-level `output` field that defaults based on
the target argument but can pin behavior:

```json
{
  "media_name": "Tacklebox-All-Test",
  "output": { "type": "iso", "label": "SUPERISO" },
  "...": "..."
}
```

SuperISO repo becomes a thin wrapper:
- Profiles (`profiles/*.tsv`) get converted to recipe JSON via a small
  shim, or kept as the source-of-truth and rendered to JSON at build time.
- `scripts/build-*.sh` collapse into one driver that calls `tacklebox build
  --iso`.

## Design: ISO output type

The ISO output is structurally close to the existing tacklebox layout —
swap "GPT partitions on a block device" for "El Torito ESP image inside
ISO9660" and "bootc install to-filesystem" for "live rootfs squashfs":

| Tacklebox today (disk)              | Tacklebox tomorrow (ISO)                          |
| ----------------------------------- | ------------------------------------------------- |
| GPT: ESP + STORE + PERSIST          | ISO9660 root with `/EFI/efi.img` (FAT ESP)        |
| ESP holds sd-boot + BLS + kernels   | Same, inside the FAT image                        |
| STORE holds per-env ostree          | `/LiveOS/<env>.rootfs.sfs` per env                |
| `bootc install` per env             | Build container + extract → `mksquashfs`          |
| Kernel cmdline `tacklebox.root=...` | Kernel cmdline `rd.live.* superiso.family=...`    |
| 95tbox-root dracut module           | 95dmsquash-live (already in live container)       |

**New internal abstractions in tacklebox:**

1. `internal/output/Target` interface:
   - `Prepare(opts) (mountpoints, error)` — set up partitions / loop / FAT image
   - `InstallEnv(env, mountpoints) error` — bootc install or sfs extract
   - `WriteBootEntry(env, mountpoints) error` — common across both
   - `Finalize(opts) error` — `losetup -d` / `xorriso -as mkisofs`

2. Two implementations: `BlockTarget` (today) and `IsoTarget` (new).

3. Recipe-level `mode` per env: `"install"` (bootc) vs `"live"` (rootfs sfs).
   Already partly modeled (see `bootable_environments[].modes`); needs to
   become a build-time selector for the install backend.

## Migration steps (incremental, keeps SuperISO building throughout)

1. **Refactor tacklebox build to a `Target` interface** (no behavior change).
   Existing `BlockTarget` wraps current code. Tests pass.
2. **Add `IsoTarget`**, initially producing a single-env ISO. Verify it boots.
3. **Add per-env live-mode install path** (extract container, mksquashfs).
   Reuse the existing `live/src/dracut/95tbox-root` module so persistence
   semantics are identical.
4. **Wire `tacklebox build --iso`** end-to-end with a multi-env recipe.
5. **Convert one SuperISO profile** to a tacklebox recipe. Build it both
   ways. Diff the resulting ISOs structurally (file lists, BLS entries).
6. **Switch SuperISO's `scripts/build-iso.sh` to call `tacklebox build
   --iso`** under the hood. Other `scripts/build-*.sh` either deleted or
   become tacklebox wrappers.
7. **Move profiles** to a `recipes/` dir at the repo root (or keep in
   SuperISO as the public face; tacklebox just consumes them).

## What stays in SuperISO

- The recipe / profile collection (TSVs or JSON) — this is the project's
  public-facing identity.
- The `live/Containerfile.generic` and `live/src/` payloads — they're
  superiso's curation of what a live env should contain.
- Documentation aimed at end users (download X.iso, dd to USB).

## What moves into / stays in tacklebox

- All build orchestration (partitioning, install, BLS, bootloader, ISO
  assembly).
- The `95tbox-root` dracut module (already canonical there; the SuperISO
  copy is just a sync target until the merger lands).
- The `Target` interface and its two implementations.

## Open questions

- **El Torito BIOS boot**: do we still care, or UEFI-only? Today's tacklebox
  is UEFI-only. SuperISO's ISO is also UEFI-only per `build-iso.sh`. Skip
  isolinux unless someone asks.
- **Hybrid disk-and-iso outputs**: a single recipe producing both a `.img`
  and an `.iso`? Probably out of scope; users can run twice.
- **Live + install in same recipe**: today an env is one or the other.
  Worth considering a "live with installer that writes the bootc image to
  internal disk" mode (basically what SuperISO's bootc-installer flow
  already does).

## Test impact

Once this lands, the CI plan in `tacklebox/TODO.md` covers SuperISO too —
the two-env smoke just runs `tacklebox build --iso fixtures/smoke-2env.json`
and boots the result the same way. No separate SuperISO CI needed.
