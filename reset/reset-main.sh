#!/usr/bin/env bash
# Runs inside the BASELINE system only, at boot, via
# homelab-reset-main.service. Overwrites the live system (bootA + rootA) with
# a copy of itself, then reboots back into it. The result is equivalent to a
# freshly flashed card: re-run install.sh afterwards to rebuild the homelab.
#
# Three independent gates, all of which must pass:
#   1. /etc/homelab-role says "baseline"  - we are not the live system
#   2. booted via tryboot                 - this boot was deliberate
#   3. arm marker on bootB                - a reset was actually requested
#
# Gate 3 is what makes booting bootB by hand safe: with no marker this exits
# before touching anything.
#
# Only three things here differ from what rootA should hold: the partitions its
# fstab and cmdline point at, the role file, and this reset machinery. Those
# are what gets undone below, and anything added to 01-create-baseline.sh needs its
# inverse here.
#
# The external data disk is never mounted here at all.
set -euo pipefail
# Path must match $COMMON_LIB in lib/common.sh - it cannot be read from there
# before that file is sourced.
# shellcheck source=../lib/common.sh
source /usr/local/lib/homelab/common.sh

LOG="$BOOT_DIR/homelab-reset.log"
# One generation back rather than appending. The rsync progress below is
# written as carriage-return updates, which is a lot of bytes for a small FAT
# partition to accumulate across resets, and a retry still has the previous
# attempt to look at.
[[ -f "$LOG" ]] && mv -f "$LOG" "$LOG.prev"
exec > >(tee "$LOG") 2>&1
echo "=== homelab-reset-main $(date -Is) ==="

need_root
[[ "$(current_role)" == "baseline" ]] || { echo "not the baseline system - refusing"; exit 0; }
booted_via_tryboot || { echo "not a tryboot boot - refusing"; exit 0; }
[[ -f "$ARM_MARKER" ]] || { echo "no reset armed - leaving the live system alone"; exit 0; }

detect_disk
echo "resetting rootfs -> $DEV_ROOT_A and boot -> $DEV_BOOT_A"

mkdir -p "$MAIN_ROOT_MNT" "$MAIN_BOOT_MNT"
mountpoint -q "$MAIN_ROOT_MNT" || mount "$DEV_ROOT_A" "$MAIN_ROOT_MNT"
mountpoint -q "$MAIN_BOOT_MNT" || mount "$DEV_BOOT_A" "$MAIN_BOOT_MNT"

# progress2 so `tail -f` on the log shows the copy moving. It has no
# newlines, so journalctl would hold it all back until the end - the log
# file is the place to watch this from.
rsync_live -aAXH --delete --info=progress2 "${RSYNC_EXCLUDES[@]}" / "$MAIN_ROOT_MNT/"
make_runtime_dirs "$MAIN_ROOT_MNT"

# autoboot.txt is preserved: it lives only on bootA and drives the whole
# mechanism. Overwriting it with a bootB copy would break the next reset.
rsync -a --delete \
    --exclude=autoboot.txt --exclude="$ARM_NAME" \
    --exclude='homelab-reset.log*' \
    "$BOOT_DIR/" "$MAIN_BOOT_MNT/"

# ---- point the freshly written system back at p1/p2 ----
set_cmdline_root "$MAIN_BOOT_MNT/cmdline.txt" "$PART_ROOT_A"
retarget_fstab "$MAIN_ROOT_MNT/etc/fstab" "$PART_BOOT_A" "$PART_ROOT_A"

echo main > "$MAIN_ROOT_MNT$ROLE_FILE"
rm -f "$MAIN_ROOT_MNT$BASELINE_STAMP"

# The system we just wrote is not a baseline and must never reset anything.
rm -f "$MAIN_ROOT_MNT/etc/systemd/system/multi-user.target.wants/homelab-reset-main.service" \
      "$MAIN_ROOT_MNT/etc/systemd/system/homelab-reset-main.service" \
      "$MAIN_ROOT_MNT/usr/local/sbin/homelab-reset-main" \
      "$MAIN_ROOT_MNT$COMMON_LIB"

sync
umount "$MAIN_BOOT_MNT"
umount "$MAIN_ROOT_MNT"

rm -f "$ARM_MARKER"
sync
echo "reset complete - rebooting. Re-run install.sh to rebuild the homelab."
sleep 2
# --no-block: we are the job systemd would otherwise wait on.
systemctl --no-block reboot
