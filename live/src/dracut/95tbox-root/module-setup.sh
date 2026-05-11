#!/bin/bash
# shellcheck disable=SC2154
# moddir, initdir, systemdsystemunitdir are set by dracut before sourcing
# this module; shellcheck has no way to know that.

check() { return 0; }
depends() { echo "base rootfs-block dracut-systemd"; return 0; }
install() {
    inst_script "$moddir/tbox-root-mount.sh" "/usr/bin/tbox-root-mount.sh"

    if dracut_module_included "systemd"; then
        inst_simple "$moddir/tbox-root.service" "${systemdsystemunitdir}/tbox-root.service"

        # Pull tbox-root.service into the initrd transaction from BOTH sides:
        # - via initrd-root-fs.target.wants (gets it activated)
        # - via ostree-prepare-root.service.requires (forces ordering even if
        #   ostree-prepare-root is started independently of the target)
        mkdir -p "${initdir}${systemdsystemunitdir}/initrd-root-fs.target.wants"
        ln_r "${systemdsystemunitdir}/tbox-root.service" \
             "${systemdsystemunitdir}/initrd-root-fs.target.wants/tbox-root.service"

        mkdir -p "${initdir}${systemdsystemunitdir}/ostree-prepare-root.service.requires"
        ln_r "${systemdsystemunitdir}/tbox-root.service" \
             "${systemdsystemunitdir}/ostree-prepare-root.service.requires/tbox-root.service"
    else
        inst_hook pre-pivot 10 "/usr/bin/tbox-root-mount.sh"
    fi
}
