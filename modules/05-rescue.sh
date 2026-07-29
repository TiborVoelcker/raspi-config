#!/usr/bin/env bash
# Wire up the tryboot path with fully independent boot partitions.
#
#   autoboot.txt (in bootA, p1)
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
detect_disk

mkdir -p "$RESCUE_BOOT_MNT" "$RESCUE_ROOT_MNT"

# ---------- rescue boot partition ----------
mountpoint -q "$RESCUE_BOOT_MNT" || mount "$DEV_BOOT_B" "$RESCUE_BOOT_MNT"

if [[ -f "$RESCUE_BOOT_MNT/config.txt" ]]; then
    skip "rescue boot partition already populated"
else
    log "copying boot partition to rescue"
    # autoboot.txt is deliberately excluded: it is only ever read from the
    # first FAT partition, and a stale copy here would only cause confusion.
    rsync -a --exclude=autoboot.txt --exclude=homelab-restore.arm \
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

if [[ -f "$RESCUE_ROOT_MNT/etc/homelab-role" ]]; then
    skip "rescue root already populated (use homelab-checkpoint to refresh)"
else
    log "cloning live system to rescue root - this takes a few minutes"
    rsync -aAXH --info=progress2 "${RSYNC_EXCLUDES[@]}" / "$RESCUE_ROOT_MNT/"

    for d in dev proc sys tmp run mnt media data boot/firmware; do
        mkdir -p "$RESCUE_ROOT_MNT/$d"
    done
    chmod 1777 "$RESCUE_ROOT_MNT/tmp"

    # Point the clone at ITS OWN boot and root partitions. Getting the boot
    # entry right matters: if the rescue system mounted bootA, a kernel upgrade
    # there would overwrite the live system's kernel and reintroduce exactly
    # the coupling this layout removes.
    retarget_fstab "$RESCUE_ROOT_MNT/etc/fstab" "$PART_BOOT_B" "$PART_ROOT_B"

    # The rescue system has no business touching the data disk.
    sed -i "\|[[:space:]]${DATA_DIR}[[:space:]]|d" "$RESCUE_ROOT_MNT/etc/fstab"

    echo rescue > "$RESCUE_ROOT_MNT/etc/homelab-role"
    echo "rescue-$(hostname)" > "$RESCUE_ROOT_MNT/etc/hostname"

    # It exists to copy files, not to run the stack.
    ln -sf /dev/null "$RESCUE_ROOT_MNT/etc/systemd/system/docker.service"
    ln -sf /dev/null "$RESCUE_ROOT_MNT/etc/systemd/system/docker.socket"

    ok "rescue root populated"
fi

# ---------- restore service, installed into the rescue system ----------
install -Dm755 "$REPO_DIR/rescue/restore.sh" \
    "$RESCUE_ROOT_MNT/usr/local/sbin/homelab-restore"
install -Dm644 "$REPO_DIR/rescue/homelab-restore.service" \
    "$RESCUE_ROOT_MNT/etc/systemd/system/homelab-restore.service"

mkdir -p "$RESCUE_ROOT_MNT/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/homelab-restore.service \
    "$RESCUE_ROOT_MNT/etc/systemd/system/multi-user.target.wants/homelab-restore.service"

date -Is > "$RESCUE_ROOT_MNT/etc/homelab-checkpoint"
ok "restore service installed into rescue system"

sync
umount "$RESCUE_ROOT_MNT" || warn "could not unmount $RESCUE_ROOT_MNT"
umount "$RESCUE_BOOT_MNT" || warn "could not unmount $RESCUE_BOOT_MNT"
