#!/usr/bin/env bash
# Carve the rescue system's boot partition (p3) and root partition (p4) out of
# unallocated space at the end of the SD card, on the running system.
#
# New partitions can be added while others are mounted. A mounted ext4 root
# cannot be shrunk, which is why this hard-fails if Raspberry Pi OS already
# auto-expanded p2 to fill the card. See USAGE.md, "Before first boot".
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd sfdisk partx blockdev udevadm mkfs.ext4 mkfs.vfat findmnt lsblk numfmt
need_tryboot_support
detect_disk

if [[ -b "$DEV_BOOT_B" && -b "$DEV_ROOT_B" ]]; then
    skip "p3 and p4 already exist"
else
    [[ -b "$DEV_BOOT_B" || -b "$DEV_ROOT_B" ]] \
        && die "partial layout: one of p3/p4 exists. Resolve by hand before continuing."

    # PARTN is a numeric column, so lsblk right-aligns it and pads on the left.
    # Strip everything but the digits or the comparison below never matches.
    root_part_num=$(lsblk -rno PARTN "$(findmnt -no SOURCE /)" 2>/dev/null \
        | tr -dc '0-9' || true)
    [[ "$root_part_num" == "$PART_ROOT_A" ]] \
        || die "root is partition ${root_part_num:-?}, expected $PART_ROOT_A - unexpected layout"

    disk_sectors=$(blockdev --getsz "$DISK")
    boot_sectors=$(blockdev --getsz "$DEV_BOOT_A")
    root_sectors=$(blockdev --getsz "$DEV_ROOT_A")
    last_end=$(partx -g -o END "$DISK" | tr -d ' ' | sort -n | tail -1)
    free_sectors=$(( disk_sectors - last_end - 1 ))
    need_sectors=$(( boot_sectors + root_sectors ))

    human() { numfmt --to=iec $(( $1 * 512 )); }

    echo "    disk        $DISK  ($(human "$disk_sectors"))"
    echo "    bootA (p1)  $(human "$boot_sectors")"
    echo "    rootA (p2)  $(human "$root_sectors")"
    echo "    free        $(human "$free_sectors")"
    echo "    required    $(human "$need_sectors")"
    echo

    if (( free_sectors < need_sectors )); then
        warn "not enough unallocated space"
        cat <<EOF

  Almost certainly the root filesystem was auto-expanded to fill the card on
  first boot, and a mounted ext4 filesystem cannot be shrunk. Re-image, and
  BEFORE the first boot delete this token from cmdline.txt on the small FAT
  partition (leave the rest of the line alone):

      resize

  Then boot and re-run install.sh. See USAGE.md, "Before first boot".

EOF
        die "aborting before touching the partition table"
    fi

    warn "about to write the partition table on $DISK"
    echo "    p3 bootB (FAT32)  $(human "$boot_sectors")"
    echo "    p4 rootB (ext4)   $(human "$root_sectors")"
    confirm "    proceed?" || die "cancelled"

    # type=c is W95 FAT32 (LBA), matching the stock Pi boot partition.
    # type=83 is Linux. Empty start = next free, 1MiB aligned by default.
    #
    # --no-reread: p1/p2 are mounted - we are running from p2 - so sfdisk's
    #   "is anyone using this disk" check fails and it refuses. Appending into
    #   free space leaves the existing partitions untouched, and partx below
    #   tells the kernel about the new ones without a full re-read.
    # -W always: wipe any filesystem signature left in the tail of the card by
    #   a previous image. Otherwise sfdisk stops to ask whether to remove it,
    #   and reads the answer from the heredoc feeding it.
    sfdisk --no-reread -W always --append "$DISK" <<EOF
size=${boot_sectors}, type=c
size=${root_sectors}, type=83
EOF

    partx -a "$DISK" 2>/dev/null || true
    udevadm settle || true
    sleep 1

    [[ -b "$DEV_BOOT_B" && -b "$DEV_ROOT_B" ]] \
        || die "kernel did not pick up new partitions - reboot and re-run"

    mkfs.vfat -F 32 -n RESCUEBOOT "$DEV_BOOT_B" >/dev/null
    mkfs.ext4 -q -L rescue "$DEV_ROOT_B"
    ok "created and formatted $DEV_BOOT_B and $DEV_ROOT_B"
fi
