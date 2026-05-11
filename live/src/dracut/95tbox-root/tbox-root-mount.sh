#!/bin/bash
# Handle subdirectory root and shared persistence for Tacklebox

TBOX_ROOT=$(getarg tacklebox.root)
TBOX_PERSIST=$(getarg tacklebox.persist)

# 1. Handle Subdirectory Root
if [ -n "$TBOX_ROOT" ]; then
    echo ">>> Tacklebox: Requesting root subdirectory /$TBOX_ROOT"
    # The main partition is already mounted at /sysroot by rootfs-block
    if [ -d "/sysroot/$TBOX_ROOT" ]; then
        echo ">>> Tacklebox: Found subdirectory. Performing move mount."
        mkdir -p /sysroot-real
        if mount -o bind "/sysroot/$TBOX_ROOT" /sysroot-real; then
            umount /sysroot
            if mount --move /sysroot-real /sysroot; then
                echo ">>> Tacklebox: Successfully switched root to /$TBOX_ROOT"
            else
                echo ">>> Tacklebox: ERROR: Failed to move mount to /sysroot"
            fi
        else
            echo ">>> Tacklebox: ERROR: Failed to bind mount subdirectory"
        fi
        rmdir /sysroot-real
    else
        echo ">>> Tacklebox: ERROR: Subdirectory /$TBOX_ROOT not found on target partition!"
        ls -la /sysroot
    fi
fi

# 2. Handle Shared Persistence
if [ -n "$TBOX_PERSIST" ]; then
    echo ">>> Tacklebox: Setting up shared persistence from $TBOX_PERSIST"
    mkdir -p /tbox-persist
    if mount "$TBOX_PERSIST" /tbox-persist; then
        OS_ID=$(echo "$TBOX_ROOT" | sed 's|.*/||')
        
        # Prepare home directory overlay
        # Lower: Shared files
        # Upper: OS-specific state
        mkdir -p /tbox-persist/home/shared
        mkdir -p "/tbox-persist/state/$OS_ID/home/upper"
        mkdir -p "/tbox-persist/state/$OS_ID/home/work"
        
        # We'll apply this mount after the real root is switched, 
        # or we can do it now if /sysroot/home exists.
        if [ -d "/sysroot/home" ]; then
            echo ">>> Tacklebox: Overlaying /home/liveuser"
            mkdir -p /sysroot/home/liveuser
            mount -t overlay overlay \
                -o lowerdir=/tbox-persist/home/shared,upperdir=/tbox-persist/state/$OS_ID/home/upper,workdir=/tbox-persist/state/$OS_ID/home/work \
                /sysroot/home/liveuser
        fi
    fi
fi
