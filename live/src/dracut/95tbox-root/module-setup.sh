#!/bin/bash
check() { return 0; }
depends() { echo "base rootfs-block"; return 0; }
install() {
    inst_hook pre-mount 10 "$moddir/tbox-root-mount.sh"
}
