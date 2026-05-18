#!/usr/bin/env python3
"""Wait for successful boot without LUKS prompt.

Used for composefs+UKI systems that don't present a LUKS passphrase prompt
because the encryption is handled at the bootloader level.
"""

import re
import sys
import time
from pathlib import Path

POLL_INTERVAL = 3
BOOT_DEADLINE = 600

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

def read_serial(path: Path) -> str:
    try:
        raw = path.read_text(errors="replace")
    except OSError:
        return ""
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw)

def main():
    if len(sys.argv) != 2:
        print("Usage: wait_boot.py <serial-log>", file=sys.stderr)
        sys.exit(1)
    
    serial_log = Path(sys.argv[1])
    deadline = time.time() + BOOT_DEADLINE
    last_len = 0
    
    while time.time() < deadline:
        text = read_serial(serial_log)
        
        # Check for successful boot
        if any(re.search(p, text, re.IGNORECASE) for p in BOOT_SUCCESS_PATTERNS):
            print("[wait_boot] System booted successfully")
            sys.exit(0)
        
        # Print new serial output
        if len(text) != last_len:
            last_len = len(text)
            lines = [l for l in text.splitlines() if l.strip()]
            if lines:
                print(f"[wait_boot] serial: {lines[-1][:120]}", flush=True)
        
        time.sleep(POLL_INTERVAL)
    
    print("[wait_boot] ERROR: timed out waiting for successful boot", file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    main()
