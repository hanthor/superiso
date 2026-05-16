#!/usr/bin/env python3
"""Detect a LUKS passphrase prompt in QEMU and type the passphrase.

The installed system presents the passphrase prompt via dracut/Plymouth on the
serial console (ttyS0) when console=ttyS0 is in the kernel cmdline.  This
helper polls the serial log for known prompt patterns, sends the passphrase
through the QEMU HMP monitor with `sendkey`, then waits for a successful boot.

Screendump polling is retained as a fallback for Plymouth graphical-only
prompts and for post-unlock boot-success detection.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


POLL_INTERVAL = 3
PLYMOUTH_WAIT = 5
PROMPT_DEADLINE = int(os.environ.get("SUPERISO_LUKS_PROMPT_TIMEOUT", "300"))
BOOT_DEADLINE = int(os.environ.get("SUPERISO_LUKS_BOOT_TIMEOUT", "600"))

# Patterns that indicate dracut/Plymouth is asking for the LUKS passphrase.
# Match case-insensitively; strip ANSI escape codes before matching.
PROMPT_PATTERNS = [
    r"enter passphrase for",
    r"please enter passphrase",
    r"please unlock disk",
    r"unlock disk.*passphrase",
    r"cryptsetup.*passphrase",
    r"ask for password",
    r"luksOpen.*password",
]

# Patterns that indicate the system booted successfully past the unlock step.
BOOT_SUCCESS_PATTERNS = [
    r"login:",
    r"Started gdm\.service",
    r"Started sddm\.service",
    r"Started display-manager\.service",
    r"Started gnome-initial-setup",
    r"Reached target graphical\.target",
    r"Welcome to Bazzite",
    r"Welcome to Aurora",
    r"Welcome to Bluefin",
]


def run_monitor_command(monitor_socket: str, command: str) -> None:
    subprocess.run(
        ["socat", "-", f"UNIX-CONNECT:{monitor_socket}"],
        input=f"{command}\n".encode(),
        capture_output=True,
        timeout=10,
        check=False,
    )


def qemu_screendump(monitor_socket: str, path: Path) -> str:
    """Return MD5 of QEMU screendump (empty string on error)."""
    import hashlib

    run_monitor_command(monitor_socket, f"screendump {path}")
    time.sleep(0.3)
    try:
        data = path.read_bytes()
        return hashlib.md5(data).hexdigest()
    except OSError:
        return ""


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


def read_serial(serial_log: Path) -> str:
    """Return serial log contents with ANSI escapes stripped."""
    try:
        raw = serial_log.read_text(errors="replace")
    except OSError:
        return ""
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw)


def serial_has(text: str, patterns: list[str]) -> bool:
    return any(re.search(p, text, re.IGNORECASE) for p in patterns)


def save_screenshot(src: Path, out_dir: Path, name: str) -> None:
    try:
        shutil.copy2(src, out_dir / name)
    except OSError:
        pass


def wait_for_prompt(
    monitor_socket: str, serial_log: Path, snap: Path, out_dir: Path
) -> None:
    """Block until the LUKS passphrase prompt is detected on serial or graphical."""
    deadline = time.time() + PROMPT_DEADLINE
    last_serial_len = 0

    while time.time() < deadline:
        text = read_serial(serial_log)

        # Fail fast: emergency shell means LUKS is not the issue—something
        # went wrong before the prompt could appear.
        if re.search(r"emergency (mode|shell)", text, re.IGNORECASE):
            print(
                "[luks-unlock] ERROR: emergency shell appeared before LUKS prompt",
                file=sys.stderr,
            )
            save_screenshot(snap, out_dir, "luks-screenshot-emergency.ppm")
            qemu_screendump(monitor_socket, snap)
            save_screenshot(snap, out_dir, "luks-screenshot-emergency.ppm")
            sys.exit(2)

        if serial_has(text, PROMPT_PATTERNS):
            print(
                "[luks-unlock] LUKS passphrase prompt detected on serial", flush=True
            )
            qemu_screendump(monitor_socket, snap)
            save_screenshot(snap, out_dir, "luks-screenshot-prompt.ppm")
            return

        if len(text) != last_serial_len:
            last_serial_len = len(text)
            # Print last line of new serial content for progress visibility.
            lines = [l for l in text.splitlines() if l.strip()]
            if lines:
                print(f"[luks-unlock] serial: {lines[-1][:120]}", flush=True)

        time.sleep(POLL_INTERVAL)

    # Serial timeout: try screendump as last-resort fallback.
    print(
        "[luks-unlock] serial timeout — falling back to screendump detection",
        file=sys.stderr,
    )
    text = read_serial(serial_log)
    if serial_has(text, BOOT_SUCCESS_PATTERNS):
        # System already booted past the LUKS stage without showing a prompt.
        # This is a test failure: the install should have required a passphrase.
        print(
            "[luks-unlock] ERROR: system booted without LUKS passphrase prompt — "
            "encryption may not have been configured correctly",
            file=sys.stderr,
        )
        sys.exit(2)

    print("[luks-unlock] ERROR: timed out waiting for LUKS prompt", file=sys.stderr)
    qemu_screendump(monitor_socket, snap)
    save_screenshot(snap, out_dir, "luks-screenshot-timeout.ppm")
    sys.exit(1)


def wait_for_boot(
    monitor_socket: str, serial_log: Path, snap: Path, out_dir: Path
) -> None:
    """Block until the system boots successfully after passphrase entry."""
    deadline = time.time() + BOOT_DEADLINE
    # Record serial length at unlock time so we only scan new content for
    # re-prompt detection (the original prompt text stays in the log).
    post_passphrase_offset = len(read_serial(serial_log))

    while time.time() < deadline:
        text = read_serial(serial_log)

        if re.search(r"emergency (mode|shell)", text, re.IGNORECASE):
            print(
                "[luks-unlock] RESULT: emergency shell after unlock", file=sys.stderr
            )
            qemu_screendump(monitor_socket, snap)
            save_screenshot(snap, out_dir, "luks-screenshot-final.ppm")
            sys.exit(2)

        if serial_has(text, BOOT_SUCCESS_PATTERNS):
            print("[luks-unlock] RESULT: boot success confirmed by serial", flush=True)
            qemu_screendump(monitor_socket, snap)
            save_screenshot(snap, out_dir, "luks-screenshot-final.ppm")
            sys.exit(0)

        # Check for a re-prompt only in new serial content after passphrase send.
        new_text = text[post_passphrase_offset:]
        if serial_has(new_text, PROMPT_PATTERNS):
            print(
                "[luks-unlock] WARNING: LUKS prompt reappeared — passphrase may be wrong",
                file=sys.stderr,
            )

        lines = [l for l in text.splitlines() if l.strip()]
        if lines:
            print(f"[luks-unlock] waiting: {lines[-1][:120]}", flush=True)

        time.sleep(POLL_INTERVAL)

    print(
        "[luks-unlock] ERROR: boot did not complete after unlock", file=sys.stderr
    )
    qemu_screendump(monitor_socket, snap)
    save_screenshot(snap, out_dir, "luks-screenshot-final.ppm")
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

    print(f"[luks-unlock] watching serial log: {serial_log}", flush=True)
    wait_for_prompt(monitor_socket, serial_log, snap, output_dir)
    print(f"[luks-unlock] waiting {PLYMOUTH_WAIT}s before entering passphrase", flush=True)
    time.sleep(PLYMOUTH_WAIT)
    qemu_send_passphrase(monitor_socket, passphrase)
    print("[luks-unlock] passphrase sent; waiting for boot completion", flush=True)
    wait_for_boot(monitor_socket, serial_log, snap, output_dir)


if __name__ == "__main__":
    main()

