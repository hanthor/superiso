# SuperISO — TODO

Cross-project tracker. Per-component lists live in:

- [`tacklebox/TODO.md`](tacklebox/TODO.md) — tacklebox features, bugs, CI plan
- [`PLAN-merge.md`](PLAN-merge.md) — merging SuperISO build orchestration into
  tacklebox so we maintain one tool, not two
- [`STATUS.md`](STATUS.md) — current state of SuperISO ISO output

## SuperISO-specific

### Adopt tacklebox as the build engine
See [`PLAN-merge.md`](PLAN-merge.md). SuperISO becomes a recipes + Containerfile
collection on top of `tacklebox build --iso`. The existing `scripts/build-*.sh`
collapse into a single thin wrapper.

### Per-env installer flow that uses tacklebox
The current SuperISO bootc-installer flow runs `bootc install` from a
booted live env. Once the merge lands, the same code path can also be
exposed as `tacklebox install` for offline use against a recipe.

### Profile → recipe converter
`profiles/*.tsv` is SuperISO's existing format. Either:
- (a) write a converter that emits tacklebox recipe JSON at build time, or
- (b) cut over the profiles to JSON wholesale and delete the TSV format.

### ISO output target in tacklebox
Tracked in [`tacklebox/TODO.md`](tacklebox/TODO.md) as part of the merger.
The substance of "what does an ISO look like" is in
[`PLAN-merge.md`](PLAN-merge.md) §"Design: ISO output type".

## Cross-cutting

### CI / regression testing
See [`tacklebox/TODO.md`](tacklebox/TODO.md) §"CI / automated testing".
Once the merger lands, SuperISO is covered automatically — the same
two-env smoke test produces an ISO instead of a disk image.

### `tacklebox verify`
See [`tacklebox/TODO.md`](tacklebox/TODO.md). Highest-leverage next
step: it's the assertion engine the CI smoke test needs, and would
have caught the cross-env content-collision bug we hit on 2026-05-11.

### bootc cross-env content collision
See [`tacklebox/TODO.md`](tacklebox/TODO.md) §"Bugs". Both
`tbox-install/aurora` and `tbox-install/bazzite` end up with the same
ostree commit when serial installs share `--mount type=bind,
src=/var/lib/containers`. Likely needs a fix in tacklebox (per-env
scratch storage) and/or a bug filed upstream against bootc.

## Done this session (2026-05-11)

- ext4 inode exhaustion in `mkfs.ext4` for `shared_store` —
  fixed by `-i 4096`.
- `tbox-root.service` ordering vs `ostree-prepare-root.service` —
  fixed by symlinking the unit into both `initrd-root-fs.target.wants/`
  and `ostree-prepare-root.service.requires/`.
- End-to-end QEMU/UEFI boot of a tacklebox-built three-env image
  reaches userspace for the first time.
