# shellcheck shell=bash
# Shared helpers. Sourced by install.sh and by every module.

set -euo pipefail

# ---------- output ----------
_c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
log()  { _c '1;34' "==> $*"; }
ok()   { _c '1;32' "  ok  $*"; }
skip() { _c '0;90' "  --  $*"; }
warn() { _c '1;33' "  !!  $*" >&2; }
die()  { _c '1;31' "  XX  $*" >&2; exit 1; }

confirm() {
    local prompt="$1"
    [[ "${HOMELAB_ASSUME_YES:-0}" == "1" ]] && return 0
    read -rp "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------- guards ----------
need_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }

need_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null || die "missing command: $c"
    done
}

need_tryboot_support() {
    [[ -e /proc/device-tree/chosen/bootloader/tryboot ]] \
        || die "firmware does not expose tryboot (needs Pi 4/5 with current EEPROM)"
}

booted_via_tryboot() {
    local v
    v=$(od -An -tu4 --endian=big /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null \
        | tr -d ' ') || return 1
    [[ "$v" == "1" ]]
}

ROLE_FILE=/etc/homelab-role
current_role() { cat "$ROLE_FILE" 2>/dev/null || echo main; }

# ---------- SD card layout ----------
# MBR, four primaries, no extended container. /data lives on a separate USB
# disk, which is what frees the fourth slot.
#
#   p1  FAT32  bootA   live system's boot partition, holds autoboot.txt
#   p2  ext4   rootA   live system
#   p3  FAT32  bootB   rescue system's OWN boot partition
#   p4  ext4   rootB   rescue system
#
# Each system mounts its own boot partition at /boot/firmware. That is the
# whole point of this layout: a kernel upgrade on one cannot touch the other.
#
# Do not convert to GPT - the firmware counts partition numbers differently
# there and tryboot becomes hard to reason about.
PART_BOOT_A=1
PART_ROOT_A=2
PART_BOOT_B=3
PART_ROOT_B=4

BOOT_DIR=/boot/firmware
DATA_DIR=/data

RESCUE_ROOT_MNT=/mnt/rescue
RESCUE_BOOT_MNT=/mnt/rescue-boot
MAIN_ROOT_MNT=/mnt/main
MAIN_BOOT_MNT=/mnt/main-boot

# Only meaningful from INSIDE the rescue system, where bootB is at $BOOT_DIR.
# The live system uses arm_restore()/disarm_restore() below instead.
ARM_MARKER="$BOOT_DIR/homelab-restore.arm"

# The /data fstab line is generated once by 01-data.sh and stashed here so a
# restore can put it back. It lives on the boot partition because that is
# reachable from both systems.
DATA_FSTAB_SNIPPET="$BOOT_DIR/homelab-data.fstab"

# Proves the external disk is really mounted and is really ours. Docker refuses
# to start without it, which is what stops containers initialising fresh
# databases into an empty mount point.
DATA_MARKER="$DATA_DIR/.homelab-data"

# Populates: DISK, DISK_ID, DEV_BOOT_A, DEV_ROOT_A, DEV_BOOT_B, DEV_ROOT_B
detect_disk() {
    local root_src pk
    root_src=$(findmnt -no SOURCE /) || die "cannot determine root source"
    pk=$(lsblk -no PKNAME "$root_src" | head -1)
    [[ -n "$pk" ]] || die "cannot determine parent disk of $root_src"
    DISK="/dev/$pk"

    [[ "$(lsblk -no PTTYPE "$DISK" | head -1)" == "dos" ]] \
        || die "partition table on $DISK is not MBR - see lib/common.sh layout notes"

    DISK_ID=$(sfdisk --disk-id "$DISK" | sed 's/^0x//')

    local sep=""
    [[ "$DISK" =~ [0-9]$ ]] && sep="p"
    DEV_BOOT_A="${DISK}${sep}${PART_BOOT_A}"
    DEV_ROOT_A="${DISK}${sep}${PART_ROOT_A}"
    DEV_BOOT_B="${DISK}${sep}${PART_BOOT_B}"
    DEV_ROOT_B="${DISK}${sep}${PART_ROOT_B}"
}

partuuid_for() { printf '%s-%02d\n' "$DISK_ID" "$1"; }

# Excluded from every rootfs copy. /data is excluded because it is a separate
# disk entirely; /boot/firmware because it is copied separately, with its own
# per-system edits.
RSYNC_EXCLUDES=(
    --exclude=/dev/*      --exclude=/proc/*  --exclude=/sys/*
    --exclude=/tmp/*      --exclude=/run/*   --exclude=/mnt/*
    --exclude=/media/*    --exclude=/lost+found
    --exclude=/data/*     --exclude=/boot/firmware/*
    --exclude=/var/swap
)

# Rewrite a cloned system's fstab so it points at its own partitions.
# usage: retarget_fstab <fstab-path> <boot-partnum> <root-partnum>
#
# Matches on mountpoint rather than on the old UUID, so it is safe to run
# repeatedly and in either direction.
retarget_fstab() {
    local fstab="$1" bootn="$2" rootn="$3"
    local boot_uuid root_uuid
    boot_uuid="PARTUUID=$(partuuid_for "$bootn")"
    root_uuid="PARTUUID=$(partuuid_for "$rootn")"

    awk -v b="$boot_uuid" -v r="$root_uuid" '
        $2 == "/boot/firmware" { print b, $2, $3, $4, $5, $6; next }
        $2 == "/"              { print r, $2, $3, $4, $5, $6; next }
        { print }
    ' "$fstab" > "${fstab}.new" && mv "${fstab}.new" "$fstab"
}

# Point a boot partition's cmdline.txt at a given root partition.
set_cmdline_root() {
    local cmdline="$1" rootn="$2"
    sed -i "s|root=PARTUUID=[^[:space:]]*|root=PARTUUID=$(partuuid_for "$rootn")|" "$cmdline"
    # First-boot machinery must never fire again on either system.
    sed -i 's|init=/usr/lib/raspberrypi-sys-mods/firstboot||g; s|systemd\.run[^[:space:]]*||g' \
        "$cmdline"
}

# ---------- arming the restore ----------
# With independent boot partitions, each system mounts its own at
# /boot/firmware. The rescue system therefore looks for the arm marker on
# bootB, so the live system must write it there - not onto its own bootA.
_with_rescue_boot() {
    local action="$1" was_mounted=0
    mkdir -p "$RESCUE_BOOT_MNT"
    if mountpoint -q "$RESCUE_BOOT_MNT"; then
        was_mounted=1
    else
        mount "$DEV_BOOT_B" "$RESCUE_BOOT_MNT" || die "cannot mount rescue boot partition"
    fi
    case "$action" in
        arm)    touch "$RESCUE_BOOT_MNT/homelab-restore.arm" ;;
        disarm) rm -f "$RESCUE_BOOT_MNT/homelab-restore.arm" ;;
        check)  [[ -f "$RESCUE_BOOT_MNT/homelab-restore.arm" ]] && ARMED=1 || ARMED=0 ;;
    esac
    sync
    (( was_mounted )) || umount "$RESCUE_BOOT_MNT"
}

arm_restore()    { _with_rescue_boot arm; }
disarm_restore() { _with_rescue_boot disarm; }
restore_armed()  { _with_rescue_boot check; [[ "$ARMED" == "1" ]]; }
