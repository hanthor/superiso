# SuperISO profile inventory

Build artifacts are currently in `/var/tmp/superiso-output/`.

Notes:
- “Image total” is the sum of `podman images` reported image sizes for the offline payloads embedded in that profile.
- “Deduped store” is the profile’s `store.sfs`, i.e. the shared overlay-driver `containers-storage` squashfs placed on the ISO at `/LiveOS/store.squashfs.img`.
- “ISO size” includes the deduped store plus one or more live root squashfs images, kernels/initramfs, and EFI boot files.

## Summary

| Profile ISO | Offline images | Image total | Deduped store on ISO | Store / image total | Final ISO |
|---|---:|---:|---:|---:|---:|
| Dakota | 2 | ~17.06 GB | 3.4 GB | ~20% | 6.7 GB |
| Aurora | 4 | ~45.29 GB | 6.9 GB | ~15% | 12 GB |
| Bazzite | 6 | ~75.33 GB | 13 GB | ~17% | 22 GB |
| Bluefin | 8 | ~86.97 GB | 18 GB | ~21% | 22 GB |

## Dakota ISO

Artifact: `/var/tmp/superiso-output/dakota/superiso-live.iso`

Live root:
- `dakota-nvidia`

Offline install images:

| Image | Reported size |
|---|---:|
| `ghcr.io/projectbluefin/dakota-nvidia:latest` | 8.85 GB |
| `ghcr.io/projectbluefin/dakota:latest` | 8.21 GB |

Totals:
- Image total: ~17.06 GB
- Deduped store: 3.4 GB
- Final ISO: 6.7 GB

## Aurora ISO

Artifact: `/var/tmp/superiso-output/aurora/superiso-live.iso`

Live root:
- `aurora-nvidia-open`

Offline install images:

| Image | Reported size |
|---|---:|
| `ghcr.io/ublue-os/aurora-dx-nvidia-open:latest` | 13 GB |
| `ghcr.io/ublue-os/aurora-dx:latest` | 14.5 GB |
| `ghcr.io/ublue-os/aurora-nvidia-open:latest` | 9.44 GB |
| `ghcr.io/ublue-os/aurora:latest` | 8.35 GB |

Totals:
- Image total: ~45.29 GB
- Deduped store: 6.9 GB
- Final ISO: 12 GB

## Bazzite ISO

Artifact: `/var/tmp/superiso-output/bazzite/superiso-live.iso`

Live roots:
- `bazzite-kde-nvidia`
- `bazzite-gnome-nvidia`

Offline install images:

| Image | Reported size |
|---|---:|
| `ghcr.io/ublue-os/bazzite-nvidia:stable` | 13 GB |
| `ghcr.io/ublue-os/bazzite-gnome-nvidia:stable` | 11.2 GB |
| `ghcr.io/ublue-os/bazzite:stable` | 11.5 GB |
| `ghcr.io/ublue-os/bazzite-gnome:stable` | 9.73 GB |
| `ghcr.io/ublue-os/bazzite-deck:stable` | 15.8 GB |
| `ghcr.io/ublue-os/bazzite-deck-gnome:stable` | 14.1 GB |

Totals:
- Image total: ~75.33 GB
- Deduped store: 13 GB
- Final ISO: 22 GB

## Bluefin ISO

Artifact: `/var/tmp/superiso-output/bluefin/superiso-live.iso`

Live root:
- `bluefin-nvidia`

Offline install images:

| Image | Reported size |
|---|---:|
| `ghcr.io/ublue-os/bluefin-dx:latest` | 13 GB |
| `ghcr.io/ublue-os/bluefin:latest` | 6.93 GB |
| `ghcr.io/ublue-os/bluefin-dx:gts` | 12.8 GB |
| `ghcr.io/ublue-os/bluefin:gts` | 6.81 GB |
| `ghcr.io/ublue-os/bluefin-dx-nvidia:latest` | 13.6 GB |
| `ghcr.io/ublue-os/bluefin-nvidia:latest` | 9.43 GB |
| `ghcr.io/ublue-os/bluefin-dx-nvidia:gts` | 14.2 GB |
| `ghcr.io/ublue-os/bluefin-nvidia:gts` | 10.2 GB |

Totals:
- Image total: ~86.97 GB
- Deduped store: 18 GB
- Final ISO: 22 GB
