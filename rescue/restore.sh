#!/usr/bin/env bash
# Runs inside the RESCUE system only, at boot, via homelab-restore.service.
# Overwrites the live system (bootA + rootA) with a copy of this rescue system,
# then reboots back into it.
#
# Three independent gates, all of which must pass:
#   1. /etc/homelab-role says "rescue"  - we are not the live system
#   2. booted via tryboot               - this boot was deliberate
#   3. arm marker on bootB              - a restore was actually requested
#
# Gate 3 is what makes booting the rescue system just to look around safe:
# with no marker this exits before touching anything.
#
# The edits below undo finalise_rescue_system() in lib/common.sh - change one
# and check the other. The external data disk is never mounted here at all.
set -euo pipefail
# Path must match $COMMON_LIB in lib/common.sh - it cannot be read from there
# before that file is sourced.
# shellcheck source=../lib/common.sh
source /usr/local/lib/homelab/common.sh

exec > >(tee -a "$BOOT_DIR/homelab-restore.log") 2>&1
echo "=== homelab-restore $(date -Is) ==="

need_root
[[ "$(current_role)" == "rescue" ]] || { echo "not the rescue system - refusing"; exit 0; }
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
# mechanism. Overwriting it with a rescue-side copy would break the next reset.
rsync -a --delete \
    --exclude=autoboot.txt --exclude="$ARM_NAME" --exclude=homelab-restore.log \
    "$BOOT_DIR/" "$MAIN_BOOT_MNT/"

# ---- undo the rescue-specific edits ----
set_cmdline_root "$MAIN_BOOT_MNT/cmdline.txt" "$PART_ROOT_A"
retarget_fstab "$MAIN_ROOT_MNT/etc/fstab" "$PART_BOOT_A" "$PART_ROOT_A"

# Put the external data disk back. 01-data.sh stashed the line on the boot
# partition precisely so a restore could find it - read our own copy, which was
# checkpointed alongside the rootfs we are restoring.
if [[ -f "$DATA_FSTAB_SNIPPET" ]] \
   && ! grep -q "[[:space:]]${DATA_DIR}[[:space:]]" "$MAIN_ROOT_MNT/etc/fstab"; then
    cat "$DATA_FSTAB_SNIPPET" >> "$MAIN_ROOT_MNT/etc/fstab"
    echo "restored $DATA_DIR fstab entry"
fi

echo main > "$MAIN_ROOT_MNT$ROLE_FILE"
set_system_hostname "$MAIN_ROOT_MNT" "$(sed 's/^rescue-//' /etc/hostname)"

rm -f "$MAIN_ROOT_MNT/etc/systemd/system/docker.service" \
      "$MAIN_ROOT_MNT/etc/systemd/system/docker.socket" \
      "$MAIN_ROOT_MNT/etc/systemd/system/multi-user.target.wants/homelab-restore.service" \
      "$MAIN_ROOT_MNT/etc/systemd/system/homelab-restore.service" \
      "$MAIN_ROOT_MNT/usr/local/sbin/homelab-restore" \
      "$MAIN_ROOT_MNT$COMMON_LIB"

sync
umount "$MAIN_BOOT_MNT"
umount "$MAIN_ROOT_MNT"

rm -f "$ARM_MARKER"
sync
echo "restore complete - rebooting into the restored system"
sleep 2
# --no-block: we are the job systemd would otherwise wait on.
systemctl --no-block reboot
