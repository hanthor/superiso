# Tacklebox Architecture & Implementation Plan

## Objective
Create a standalone Go CLI application (`tacklebox`) designed to provision, populate, and update multi-tenant bootable flash drives and disks using `bootc` container images.

## Architecture

### 1. The Engine: Orchestrating `bootc`
Tacklebox will act as an intelligent wrapper around the existing `bootc` binary, avoiding reimplementation of complex container extraction, composefs handling, ostree deployment, and SELinux labeling.
*   For each image in the `media-recipe.json`, Tacklebox will execute:
    `bootc install to-filesystem --skip-finalize --bootloader none /path/to/usb/store`
*   This strictly forbids `bootc` from interacting with the bootloader.

### 2. The Manager: Universal Bootloader (`systemd-boot`)
Tacklebox takes absolute, dictatorial control over the EFI System Partition (ESP) to resolve bootloader conflicts between different OS backends (e.g., Ostree vs. Composefs).
*   **Standardization:** The ESP will be formatted and loaded with a fresh copy of `systemd-boot`.
*   **Artifact Extraction:** Tacklebox will extract `vmlinuz` and `initramfs` from the `bootc` populated stores and place them into isolated directories on the ESP (e.g., `/EFI/<os_name>/`).
*   **BLS Generation:** Tacklebox will programmatically generate Boot Loader Specification (BLS) `.conf` files. It bridges the gap between backends by injecting specific kernel arguments (`ostree=...` for Ostree, `rootflags=subvol=...` for Composefs).

### 3. Ephemeral vs. Persistent Modes
Tacklebox will support deploying the same OS image with different boot modalities:
*   **Live (Ephemeral):** Passes kernel arguments like `rd.live.overlay=tmpfs` so that changes disappear on reboot.
*   **Persistent:** Passes standard root arguments, allowing the USB drive to act as a fully portable, persistent OS.
*   Internal bootloader updater services (e.g., `bootupd`) will be masked/disabled inside the provisioned OSes to prevent them from corrupting the ESP.

### 4. The Update Manager
Updates are managed exclusively by Tacklebox, ensuring atomic, conflict-free rollouts.
*   Users run `tacklebox update <os_name>` from within a booted environment.
*   Tacklebox orchestrates `bootc` (or `skopeo`) to pull the new container layers into the shared store.
*   Tacklebox extracts the new kernel/initramfs, places them on the ESP, and writes a new BLS entry.
*   Once the new BLS entry is written (an atomic file operation), the update is complete. Old entries and layers can be garbage collected later.

## Phased Implementation Strategy

### Phase 1: Foundation & CLI Scaffolding
*   Initialize the Go module (`tacklebox`).
*   Implement the CLI framework (e.g., using `cobra` or `urfave/cli`).
*   Implement the JSON parser for `media-recipe.json`.
*   Define the core data structures representing Disks, Partitions, and Payloads.

### Phase 2: Disk & Storage Management
*   Implement disk formatting and partitioning logic (using wrappers around `sgdisk`, `mkfs.fat`, `mkfs.btrfs`, or `systemd-repart`).
*   Establish the target partition layout: ESP (FAT32) + Shared Store (Btrfs).

### Phase 3: The Bootc Orchestrator
*   Implement the `bootc` execution engine.
*   Handle pulling images to the shared store via `bootc install to-filesystem`.
*   Implement logic to search the deployed root for the active kernel (`vmlinuz`) and `initramfs.img`.

### Phase 4: Bootloader Management
*   Implement `systemd-boot` installation to the ESP (`bootctl install`).
*   Implement the BLS Configuration Generator.
*   Add logic to differentiate between ostree and composefs kernel argument requirements.

### Phase 5: The Update Lifecycle
*   Implement the `tacklebox update` command.
*   Add logic for safe BLS entry rotation and fallback handling.
*   Implement pruning/garbage collection of old deployment layers and kernels.

## Future Roadmap
*   Integration into `tuna-os/fisherman` as a submodule or plugin.
*   Support for automated testing via QEMU.