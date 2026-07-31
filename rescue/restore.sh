#!/usr/bin/env bash
# Runs inside the BASELINE system only, at boot, via homelab-restore.service.
# Overwrites the live system (bootA + rootA) with a copy of itself, then
# reboots back into it. The result is equivalent to a freshly flashed card:
# re-run install.sh afterwards to rebuild the homelab on top.
#
# Three independent gates, all of which must pass:
#   1. /etc/homelab-role says "rescue"  - we are not the live system
#   2. booted via tryboot               - this boot was deliberate
#   3. arm marker on bootB              - a restore was actually requested
#
# Gate 3 is what makes booting bootB by hand safe: with no marker this exits
# before touching anything.
#
# There is very little to undo on the way back, because the baseline is a
# pristine clone rather than a customised system. Only three things differ from
# what rootA should hold: the partitions its fstab and cmdline point at, the
# role file, and this restore machinery. Anything added to 01-rescue.sh needs
# its inverse here.
#
# The external data disk is never mounted here at all.
set -euo pipefail
# Path must match $COMMON_LIB in lib/common.sh - it cannot be read from there
# before that file is sourced.
# shellcheck source=../lib/common.sh
source /usr/local/lib/homelab/common.sh

exec > >(tee -a "$BOOT_DIR/homelab-restore.log") 2>&1
echo "=== homelab-restore $(date -Is) ==="

need_root
[[ "$(current_role)" == "rescue" ]] || { echo "not the baseline system - refusing"; exit 0; }
booted_via_tryboot || { echo "not a tryboot boot - refusing"; exit 0; }
[[ -f "$ARM_MARKER" ]] || { echo "no restore armed - leaving the live system alone"; exit 0; }

detect_disk
echo "restoring rootfs -> $DEV_ROOT_A and boot -> $DEV_BOOT_A"

mkdir -p "$MAIN_ROOT_MNT" "$MAIN_BOOT_MNT"
mountpoint -q "$MAIN_ROOT_MNT" || mount "$DEV_ROOT_A" "$MAIN_ROOT_MNT"
mountpoint -q "$MAIN_BOOT_MNT" || mount "$DEV_BOOT_A" "$MAIN_BOOT_MNT"

rsync -aAXH --delete "${RSYNC_EXCLUDES[@]}" / "$MAIN_ROOT_MNT/"
make_runtime_dirs "$MAIN_ROOT_MNT"

# autoboot.txt is preserved: it lives only on bootA and drives the whole
# mechanism. Overwriting it with a bootB copy would break the next reset.
rsync -a --delete \
    --exclude=autoboot.txt --exclude="$ARM_NAME" --exclude=homelab-restore.log \
    "$BOOT_DIR/" "$MAIN_BOOT_MNT/"

# ---- point the restored system back at p1/p2 ----
set_cmdline_root "$MAIN_BOOT_MNT/cmdline.txt" "$PART_ROOT_A"
retarget_fstab "$MAIN_ROOT_MNT/etc/fstab" "$PART_BOOT_A" "$PART_ROOT_A"

echo main > "$MAIN_ROOT_MNT$ROLE_FILE"
rm -f "$MAIN_ROOT_MNT$BASELINE_STAMP"

# The restored system is not a baseline and must never restore anything.
rm -f "$MAIN_ROOT_MNT/etc/systemd/system/multi-user.target.wants/homelab-restore.service" \
      "$MAIN_ROOT_MNT/etc/systemd/system/homelab-restore.service" \
      "$MAIN_ROOT_MNT/usr/local/sbin/homelab-restore" \
      "$MAIN_ROOT_MNT$COMMON_LIB"

sync
umount "$MAIN_BOOT_MNT"
umount "$MAIN_ROOT_MNT"

rm -f "$ARM_MARKER"
sync
echo "restore complete - rebooting. Re-run install.sh to rebuild the homelab."
sleep 2
# --no-block: we are the job systemd would otherwise wait on.
systemctl --no-block reboot
