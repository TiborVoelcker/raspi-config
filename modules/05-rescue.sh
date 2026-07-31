#!/usr/bin/env bash
# First-time setup of the rescue system: clone the live boot+root onto p3/p4,
# retarget the clone at its own partitions, and write autoboot.txt.
#
#   autoboot.txt (on bootA, p1)
#       [all]     tryboot_a_b=1   boot_partition=1   -> normal boot, bootA
#       [tryboot]                 boot_partition=3   -> rescue boot, bootB
#
# tryboot_a_b=1 tells the firmware to read the ordinary config.txt from
# whichever partition it landed on, rather than looking for a tryboot.txt. That
# makes the switch happen at the PARTITION level: kernel, device trees,
# overlays and cmdline all come from bootB, so the rescue system shares nothing
# with the live one and cannot be disturbed by a kernel upgrade on it.
#
# The tryboot flag is one-shot and cannot be set by a cold boot, so any
# ordinary reboot - or a power cut - lands back on bootA with no action needed.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd rsync
detect_disk
[[ -b "$DEV_BOOT_B" && -b "$DEV_ROOT_B" ]] \
    || die "no rescue partitions - 00-storage.sh should have created them"

mkdir -p "$RESCUE_BOOT_MNT" "$RESCUE_ROOT_MNT"

# ---------- rescue boot partition ----------
mountpoint -q "$RESCUE_BOOT_MNT" || mount "$DEV_BOOT_B" "$RESCUE_BOOT_MNT"

if [[ -f "$RESCUE_BOOT_MNT/config.txt" ]]; then
    skip "rescue boot partition already populated"
else
    log "copying boot partition to rescue"
    # autoboot.txt is deliberately excluded: it is only ever read from the
    # first FAT partition, and a stale copy here would only cause confusion.
    rsync -a --exclude=autoboot.txt --exclude="$ARM_NAME" \
        --exclude=homelab-restore.log \
        "$BOOT_DIR/" "$RESCUE_BOOT_MNT/"

    set_cmdline_root "$RESCUE_BOOT_MNT/cmdline.txt" "$PART_ROOT_B"
    ok "rescue boot partition points at rootB"
fi

# ---------- autoboot.txt on the live boot partition ----------
if [[ -f "$BOOT_DIR/autoboot.txt" ]]; then
    skip "autoboot.txt present"
else
    cat > "$BOOT_DIR/autoboot.txt" <<EOF
[all]
tryboot_a_b=1
boot_partition=${PART_BOOT_A}

[tryboot]
boot_partition=${PART_BOOT_B}
EOF
    ok "wrote autoboot.txt"
fi

# ---------- rescue root partition ----------
mountpoint -q "$RESCUE_ROOT_MNT" || mount "$DEV_ROOT_B" "$RESCUE_ROOT_MNT"

if [[ -f "$RESCUE_ROOT_MNT$ROLE_FILE" ]]; then
    skip "rescue root already populated (use homelab-checkpoint to refresh)"
else
    log "cloning live system to rescue root - this takes a few minutes"
    rsync -aAXH --info=progress2 "${RSYNC_EXCLUDES[@]}" / "$RESCUE_ROOT_MNT/"
    make_runtime_dirs "$RESCUE_ROOT_MNT"
    # Only a real rootfs sync gets to claim a checkpoint timestamp.
    date -Is > "$RESCUE_ROOT_MNT/etc/homelab-checkpoint"
    ok "rescue root populated"
fi

# Outside the guard, so re-running install.sh picks up repo changes to the
# restore script and its unit even when the clone is already there.
finalise_rescue_system
ok "rescue system configured"

sync
umount "$RESCUE_ROOT_MNT" || warn "could not unmount $RESCUE_ROOT_MNT"
umount "$RESCUE_BOOT_MNT" || warn "could not unmount $RESCUE_BOOT_MNT"
