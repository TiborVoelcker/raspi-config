#!/usr/bin/env bash
# Runs inside the RESCUE system only. Overwrites the live system (bootA + rootA)
# with a copy of this rescue system, then reboots back into it.
#
# Three independent gates, all of which must pass:
#   1. /etc/homelab-role says "rescue"      - we are not the live system
#   2. booted via tryboot                   - this boot was deliberate
#   3. arm marker on the rescue boot part.  - a restore was actually requested
#
# Gate 3 is why homelab-rescue-shell is safe: it clears the marker, so you can
# boot in and look around without touching the live system.
#
# The external data disk is never mounted here at all.
set -euo pipefail

BOOT_DIR=/boot/firmware
ARM_MARKER="$BOOT_DIR/homelab-restore.arm"
LOG="$BOOT_DIR/homelab-restore.log"

exec > >(tee -a "$LOG") 2>&1
echo "=== homelab-restore $(date -Is) ==="

[[ "$(cat /etc/homelab-role 2>/dev/null)" == "rescue" ]] || {
    echo "not the rescue system - refusing"; exit 0; }

tryboot=$(od -An -tu4 --endian=big /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d ' ')
[[ "$tryboot" == "1" ]] || { echo "not a tryboot boot - refusing"; exit 0; }

[[ -f "$ARM_MARKER" ]] || { echo "no restore armed - leaving the live system alone"; exit 0; }

root_src=$(findmnt -no SOURCE /)
disk="/dev/$(lsblk -no PKNAME "$root_src" | head -1)"
sep=""; [[ "$disk" =~ [0-9]$ ]] && sep="p"
disk_id=$(sfdisk --disk-id "$disk" | sed 's/^0x//')

target_boot="${disk}${sep}1"
target_root="${disk}${sep}2"

echo "restoring rootfs -> $target_root and boot -> $target_boot"

MAIN_ROOT=/mnt/main
MAIN_BOOT=/mnt/main-boot
mkdir -p "$MAIN_ROOT" "$MAIN_BOOT"
mountpoint -q "$MAIN_ROOT" || mount "$target_root" "$MAIN_ROOT"
mountpoint -q "$MAIN_BOOT" || mount "$target_boot" "$MAIN_BOOT"

# ---- rootfs ----
rsync -aAXH --delete \
    --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* \
    --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* \
    --exclude=/media/* --exclude=/lost+found \
    --exclude=/data/* --exclude=/boot/firmware/* \
    --exclude=/var/swap \
    / "$MAIN_ROOT/"

for d in dev proc sys tmp run mnt media data boot/firmware; do
    mkdir -p "$MAIN_ROOT/$d"
done
chmod 1777 "$MAIN_ROOT/tmp"

# ---- boot partition ----
# autoboot.txt is preserved: it lives only on bootA and drives the whole
# mechanism. Overwriting it with a rescue-side copy would break the next reset.
rsync -a --delete \
    --exclude=autoboot.txt --exclude=homelab-restore.arm --exclude=homelab-restore.log \
    --exclude=homelab-data.fstab \
    "$BOOT_DIR/" "$MAIN_BOOT/"

sed -i "s|root=PARTUUID=[^[:space:]]*|root=PARTUUID=${disk_id}-02|" "$MAIN_BOOT/cmdline.txt"

# ---- undo the rescue-specific edits ----
awk -v b="PARTUUID=${disk_id}-01" -v r="PARTUUID=${disk_id}-02" '
    $2 == "/boot/firmware" { print b, $2, $3, $4, $5, $6; next }
    $2 == "/"              { print r, $2, $3, $4, $5, $6; next }
    { print }
' "$MAIN_ROOT/etc/fstab" > "$MAIN_ROOT/etc/fstab.new"
mv "$MAIN_ROOT/etc/fstab.new" "$MAIN_ROOT/etc/fstab"

# Put the external data disk back into the restored system's fstab.
if [[ -f "$MAIN_BOOT/homelab-data.fstab" ]] && ! grep -q "[[:space:]]/data[[:space:]]" "$MAIN_ROOT/etc/fstab"; then
    cat "$MAIN_BOOT/homelab-data.fstab" >> "$MAIN_ROOT/etc/fstab"
    echo "restored /data fstab entry"
fi

echo main > "$MAIN_ROOT/etc/homelab-role"
sed 's/^rescue-//' /etc/hostname > "$MAIN_ROOT/etc/hostname"

rm -f "$MAIN_ROOT/etc/systemd/system/docker.service" \
      "$MAIN_ROOT/etc/systemd/system/docker.socket" \
      "$MAIN_ROOT/etc/systemd/system/multi-user.target.wants/homelab-restore.service" \
      "$MAIN_ROOT/etc/systemd/system/homelab-restore.service" \
      "$MAIN_ROOT/usr/local/sbin/homelab-restore"

sync
umount "$MAIN_BOOT"
umount "$MAIN_ROOT"

rm -f "$ARM_MARKER"
sync
echo "restore complete - rebooting into the restored system"
sleep 2
systemctl reboot
