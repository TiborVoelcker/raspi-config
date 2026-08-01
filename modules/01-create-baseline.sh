#!/usr/bin/env bash
# Capture the baseline: a copy of this system exactly as it came off the SD
# card image, onto p3/p4, plus the autoboot.txt that lets us tryboot into it.
#
# Runs FIRST, before any module that changes the system, so the baseline is the
# pristine flashed OS - no /data mount, no apt upgrade, no Docker, no services.
# Restoring it is meant to be equivalent to re-flashing the card, after which
# install.sh rebuilds everything on top.
#
# Captured exactly once. The baseline only ever boots, overwrites the main
# image and reboots, so nothing here goes further than making it bootable.
#
#   autoboot.txt (on bootA, p1)
#       [all]     tryboot_a_b=1   boot_partition=1   -> normal boot, bootA
#       [tryboot]                 boot_partition=3   -> baseline boot, bootB
#
# tryboot_a_b=1 tells the firmware to read the ordinary config.txt from
# whichever partition it landed on, rather than looking for a tryboot.txt. That
# makes the switch happen at the PARTITION level: kernel, device trees,
# overlays and cmdline all come from bootB, so the baseline shares nothing with
# the live system and cannot be disturbed by a kernel upgrade on it.
#
# The tryboot flag is one-shot and cannot be set by a cold boot, so any
# ordinary reboot - or a power cut - lands back on bootA with no action needed.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd rsync
detect_disk
[[ -b "$DEV_BOOT_B" && -b "$DEV_ROOT_B" ]] \
    || die "p3/p4 do not exist - 00-storage.sh should have created them"

mkdir -p "$BASELINE_BOOT_MNT" "$BASELINE_ROOT_MNT"
mountpoint -q "$BASELINE_BOOT_MNT" || mount "$DEV_BOOT_B" "$BASELINE_BOOT_MNT"
mountpoint -q "$BASELINE_ROOT_MNT" || mount "$DEV_ROOT_B" "$BASELINE_ROOT_MNT"

# ---------- boot partition ----------
if [[ -f "$BASELINE_BOOT_MNT/config.txt" ]]; then
    skip "bootB already populated"
else
    log "copying boot partition to bootB"
    # autoboot.txt is deliberately excluded: it is only ever read from the
    # first FAT partition, and a stale copy here would only cause confusion.
    rsync -a --exclude=autoboot.txt --exclude="$ARM_NAME" \
        --exclude='homelab-reset.log*' \
        "$BOOT_DIR/" "$BASELINE_BOOT_MNT/"

    set_cmdline_root "$BASELINE_BOOT_MNT/cmdline.txt" "$PART_ROOT_B"
    ok "bootB points at rootB"
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

# ---------- the baseline itself ----------
# Guarded on the stamp rather than the role file, which is written earlier: a
# clone interrupted midway should be finished by the next install.sh run, not
# skipped as if it were complete.
if [[ -f "$BASELINE_ROOT_MNT$BASELINE_STAMP" ]]; then
    skip "baseline captured $(cat "$BASELINE_ROOT_MNT$BASELINE_STAMP")"
else
    log "capturing baseline to rootB - this takes a few minutes"
    # --delete so a recapture onto a used rootB leaves the flashed system and
    # nothing else. On a first capture rootB is empty and it does nothing.
    rsync_live -aAXH --delete --info=progress2 "${RSYNC_EXCLUDES[@]}" / "$BASELINE_ROOT_MNT/"
    make_runtime_dirs "$BASELINE_ROOT_MNT"

    # Point the clone at ITS OWN partitions. If it mounted bootA instead, a
    # kernel upgrade there would overwrite the live system's kernel and
    # reintroduce exactly the coupling this layout removes.
    retarget_fstab "$BASELINE_ROOT_MNT/etc/fstab" "$PART_BOOT_B" "$PART_ROOT_B"

    date -Is > "$BASELINE_ROOT_MNT$BASELINE_STAMP"
    ok "baseline captured"
fi

# Outside the guard, so re-running install.sh picks up repo changes to the
# reset script and its unit without recapturing the baseline.

# Gate 1 of the reset, and what stops install.sh provisioning from here.
echo baseline > "$BASELINE_ROOT_MNT$ROLE_FILE"
install -Dm755 "$REPO_DIR/reset/reset-main.sh" \
    "$BASELINE_ROOT_MNT/usr/local/sbin/homelab-reset-main"
install -Dm644 "$REPO_DIR/lib/common.sh" "$BASELINE_ROOT_MNT$COMMON_LIB"
install -Dm644 "$REPO_DIR/reset/homelab-reset-main.service" \
    "$BASELINE_ROOT_MNT/etc/systemd/system/homelab-reset-main.service"
mkdir -p "$BASELINE_ROOT_MNT/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/homelab-reset-main.service \
    "$BASELINE_ROOT_MNT/etc/systemd/system/multi-user.target.wants/homelab-reset-main.service"
ok "reset service installed into the baseline"

sync
umount "$BASELINE_ROOT_MNT" || warn "could not unmount $BASELINE_ROOT_MNT"
umount "$BASELINE_BOOT_MNT" || warn "could not unmount $BASELINE_BOOT_MNT"
