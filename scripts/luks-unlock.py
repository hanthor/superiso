#!/usr/bin/env python3
"""Detect a Plymouth LUKS prompt in QEMU and type the passphrase.

The installed system renders the passphrase prompt on the graphical console, so
CI cannot rely on the serial console alone. This helper polls QEMU screendumps
through the HMP monitor socket, saves diagnostic screenshots, sends the
passphrase with HMP `sendkey`, and waits for the installed desktop to appear.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


POLL_INTERVAL = 3
PLYMOUTH_WAIT = 10
PROMPT_DEADLINE = int(os.environ.get("SUPERISO_LUKS_PROMPT_TIMEOUT", "300"))
BOOT_DEADLINE = int(os.environ.get("SUPERISO_LUKS_BOOT_TIMEOUT", "300"))


def run_monitor_command(monitor_socket: str, command: str) -> None:
    subprocess.run(
        ["socat", "-", f"UNIX-CONNECT:{monitor_socket}"],
        input=f"{command}\n".encode(),
        capture_output=True,
        timeout=10,
        check=False,
    )


def qemu_screendump(monitor_socket: str, path: Path) -> tuple[float, str]:
    """Return average sampled brightness and MD5 for a QEMU PPM screendump."""
    run_monitor_command(monitor_socket, f"screendump {path}")
    time.sleep(0.5)

    try:
        data = path.read_bytes()
    except OSError:
        return -1.0, ""

    try:
        header_end = data.index(b"255\n") + 4
    except ValueError:
        return -1.0, ""

    pixels = data[header_end:]
    if not pixels:
        return -1.0, ""

    sample = pixels[::100]
    brightness = sum(sample) / len(sample)
    return brightness, hashlib.md5(data).hexdigest()


def qemu_send_passphrase(monitor_socket: str, passphrase: str) -> None:
    key_map = {c: c for c in "abcdefghijklmnopqrstuvwxyz0123456789"}
    key_map.update({"-": "minus", "_": "shift-minus", " ": "spc"})

    for char in passphrase:
        key = key_map.get(char)
        if key is None:
            print(f"[luks-unlock] WARNING: unsupported key {char!r}", file=sys.stderr)
            continue
        run_monitor_command(monitor_socket, f"sendkey {key}")
        time.sleep(0.1)
    run_monitor_command(monitor_socket, "sendkey ret")


def serial_state(serial_log: Path) -> str:
    try:
        raw = serial_log.read_text(errors="replace")
    except OSError:
        return ""

    stripped = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw)
    flat = " ".join(stripped.split())

    if "emergency mode" in stripped or "emergency shell" in stripped:
        return "emergency"
    if "Please enter passphrase for disk" in raw:
        return "plymouth"
    if "Started gnome-initial-setup" in flat:
        return "desktop"
    if "Started gdm.service" in flat or "Started GNOME Display Manager" in flat:
        return "desktop"
    if "Started sddm.service" in flat or "Started Simple Desktop Display Manager" in flat:
        return "desktop"
    if "Started display-manager.service" in flat:
        return "desktop"
    return ""


def save_screenshot(src: Path, out_dir: Path, name: str) -> None:
    try:
        shutil.copy2(src, out_dir / name)
    except OSError:
        pass


def wait_for_prompt(monitor_socket: str, serial_log: Path, snap: Path, out_dir: Path) -> str:
    content_threshold = 0.5
    stable_polls = 2
    had_content = False
    stable_count = 0
    previous_hash = ""

    deadline = time.time() + PROMPT_DEADLINE
    while time.time() < deadline:
        state = serial_state(serial_log)
        if state == "plymouth":
            print("[luks-unlock] Plymouth prompt detected on serial", flush=True)
            _, md5 = qemu_screendump(monitor_socket, snap)
            save_screenshot(snap, out_dir, "luks-screenshot-plymouth.ppm")
            return md5
        if state == "emergency":
            print("[luks-unlock] emergency shell before passphrase", file=sys.stderr)
            sys.exit(2)

        brightness, md5 = qemu_screendump(monitor_socket, snap)
        print(
            f"[luks-unlock] screendump brightness={brightness:.2f} hash={md5[:8]}",
            flush=True,
        )

        if brightness < 0:
            stable_count = 0
            time.sleep(POLL_INTERVAL)
            continue

        if not had_content and brightness > content_threshold:
            had_content = True
            print("[luks-unlock] framebuffer content detected", flush=True)

        if had_content:
            stable_count = stable_count + 1 if md5 == previous_hash else 0
            previous_hash = md5

        if had_content and stable_count >= stable_polls:
            print("[luks-unlock] stable graphical prompt detected", flush=True)
            save_screenshot(snap, out_dir, "luks-screenshot-plymouth.ppm")
            return md5

        time.sleep(POLL_INTERVAL)

    print("[luks-unlock] ERROR: timed out waiting for LUKS prompt", file=sys.stderr)
    sys.exit(1)


def wait_for_boot(monitor_socket: str, serial_log: Path, snap: Path, out_dir: Path, prompt_hash: str) -> None:
    deadline = time.time() + BOOT_DEADLINE
    screen_changed = False
    stable_count = 0
    previous_hash = prompt_hash

    while time.time() < deadline:
        state = serial_state(serial_log)
        if state == "emergency":
            print("[luks-unlock] RESULT: emergency shell after unlock", flush=True)
            save_screenshot(snap, out_dir, "luks-screenshot-final.ppm")
            sys.exit(2)

        brightness, md5 = qemu_screendump(monitor_socket, snap)
        print(
            f"[luks-unlock] post-unlock brightness={brightness:.2f} hash={md5[:8]}",
            flush=True,
        )

        if md5 and md5 != prompt_hash:
            screen_changed = True

        if state == "desktop":
            print("[luks-unlock] RESULT: desktop confirmed by serial", flush=True)
            save_screenshot(snap, out_dir, "luks-screenshot-final.ppm")
            sys.exit(0)

        stable_count = stable_count + 1 if md5 == previous_hash else 0
        previous_hash = md5

        if screen_changed and stable_count >= 1:
            save_screenshot(snap, out_dir, "luks-screenshot-final.ppm")
            if brightness > 1.8:
                print("[luks-unlock] RESULT: desktop-like framebuffer detected", flush=True)
                sys.exit(0)
            print("[luks-unlock] RESULT: dark stable framebuffer after unlock", flush=True)
            sys.exit(2)

        time.sleep(5)

    print("[luks-unlock] ERROR: boot did not complete after unlock", file=sys.stderr)
    sys.exit(2)


def main() -> None:
    if len(sys.argv) != 5:
        print(
            "Usage: luks-unlock.py <monitor-socket> <passphrase> <serial-log> <output-dir>",
            file=sys.stderr,
        )
        sys.exit(1)

    monitor_socket, passphrase, serial_log_arg, output_dir_arg = sys.argv[1:]
    serial_log = Path(serial_log_arg)
    output_dir = Path(output_dir_arg)
    output_dir.mkdir(parents=True, exist_ok=True)
    snap = output_dir / "luks-unlock-snap.ppm"

    print(f"[luks-unlock] watching {monitor_socket}", flush=True)
    prompt_hash = wait_for_prompt(monitor_socket, serial_log, snap, output_dir)
    print(f"[luks-unlock] waiting {PLYMOUTH_WAIT}s before entering passphrase", flush=True)
    time.sleep(PLYMOUTH_WAIT)
    qemu_send_passphrase(monitor_socket, passphrase)
    print("[luks-unlock] passphrase sent; waiting for installed boot", flush=True)
    wait_for_boot(monitor_socket, serial_log, snap, output_dir, prompt_hash)


if __name__ == "__main__":
    main()
