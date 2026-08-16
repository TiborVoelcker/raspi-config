#!/usr/bin/env bash
# Lay out the SD card: carve the baseline's partitions out of the unallocated
# tail, then grow rootA into everything left over.
#
#   p1 bootA | p2 rootA .... grows .... | p3 bootB | p4 rootB
#
# bootB and rootB go at the very END of the card, so the free space lands
# between rootA and bootB where rootA can grow into it. rootB only ever holds a
# copy of the flashed system, so it needs no more room than the image's own
# root partition.
#
# All of this runs on the mounted, running system: partitions can be added
# while others are in use, and ext4 grows online. It cannot be SHRUNK, which is
# why this hard-fails if Raspberry Pi OS already auto-expanded p2 to fill the
# card. See README.md, "Before first boot".
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd sfdisk partx blockdev udevadm mkfs.ext4 mkfs.vfat resize2fs \
    findmnt lsblk numfmt
need_tryboot_support
detect_disk

# -- : sizes come out negative on a card with no room, and numfmt would read
# the leading - as an option.
human()     { numfmt --to=iec -- "$(( $1 * 512 ))"; }
part_start() { partx -g -o START --nr "$1" "$DISK" | tr -dc '0-9'; }
part_end()   { partx -g -o END   --nr "$1" "$DISK" | tr -dc '0-9'; }

# sfdisk's default alignment, and what every Pi image is already aligned to.
ALIGN=2048

# ---------- the baseline's partitions ----------
if [[ -b "$DEV_BOOT_B" && -b "$DEV_ROOT_B" ]]; then
    skip "p3 and p4 already exist"
else
    [[ -b "$DEV_BOOT_B" || -b "$DEV_ROOT_B" ]] \
        && die "partial layout: one of p3/p4 exists. Resolve by hand before continuing."

    # PARTN is right-aligned and padded, so strip everything but the digits or
    # the comparison below never matches.
    root_part_num=$(lsblk -rno PARTN "$(findmnt -no SOURCE /)" 2>/dev/null \
        | tr -dc '0-9' || true)
    [[ "$root_part_num" == "$PART_ROOT_A" ]] \
        || die "root is partition ${root_part_num:-?}, expected $PART_ROOT_A - unexpected layout"

    disk_sectors=$(blockdev --getsz "$DISK")
    boot_sectors=$(blockdev --getsz "$DEV_BOOT_A")
    root_sectors=$(blockdev --getsz "$DEV_ROOT_A")
    root_a_start=$(part_start "$PART_ROOT_A")
    root_a_end=$(part_end "$PART_ROOT_A")

    # Pack both from the end of the card, keeping 1MiB alignment.
    root_b_start=$(( (disk_sectors - root_sectors) / ALIGN * ALIGN ))
    boot_b_start=$(( (root_b_start - boot_sectors) / ALIGN * ALIGN ))

    grows_to=""
    (( boot_b_start > root_a_end )) \
        && grows_to="  ->  $(human $(( boot_b_start - root_a_start )))"

    log "disk        $DISK  ($(human "$disk_sectors"))"
    log "bootA (p1)  $(human "$boot_sectors")"
    log "rootA (p2)  $(human "$root_sectors")$grows_to"
    log "bootB (p3)  $(human "$boot_sectors")"
    log "rootB (p4)  $(human "$root_sectors")"
    echo

    if (( boot_b_start <= root_a_end )); then
        warn "not enough unallocated space"
        echo
        log 'Almost certainly the root filesystem was auto-expanded to fill the'
        log 'card on first boot, and a mounted ext4 filesystem cannot be shrunk.'
        log 'Re-image, and BEFORE the first boot delete this token from'
        log 'cmdline.txt on the small FAT partition (leave the rest alone):'
        echo
        log '    resize'
        echo
        log 'Then boot and re-run install.sh. See README.md, "Before first boot".'
        echo
        die "aborting before touching the partition table"
    fi

    warn "about to write the partition table on $DISK"
    confirm "      proceed?" || die "cancelled"

    # type=c is W95 FAT32 (LBA), matching the stock Pi boot partition; type=83
    # is Linux.
    #
    # --no-reread / --no-tell-kernel: we are running from p2, so sfdisk refuses
    #   to write and the kernel cannot re-read the table. partx below picks up
    #   the new partitions instead.
    # -W always: wipe any filesystem signature a previous image left in the
    #   tail of the card. Otherwise sfdisk stops to ask, and reads the answer
    #   from the heredoc feeding it.
    sfdisk --no-reread --no-tell-kernel -W always --append "$DISK" >/dev/null <<EOF
start=${boot_b_start}, size=${boot_sectors}, type=c
start=${root_b_start}, size=${root_sectors}, type=83
EOF

    partx -a "$DISK" 2>/dev/null || true
    udevadm settle || true
    sleep 1

    [[ -b "$DEV_BOOT_B" && -b "$DEV_ROOT_B" ]] \
        || die "kernel did not pick up new partitions - reboot and re-run"

    mkfs.vfat -F 32 -n bootbase "$DEV_BOOT_B" >/dev/null
    mkfs.ext4 -q -L rootbase "$DEV_ROOT_B"
    ok "created and formatted $DEV_BOOT_B and $DEV_ROOT_B"
fi

# ---------- grow rootA into the gap before bootB ----------
# Separate from the block above so an interrupted run picks up where it left
# off, and so a card that gains space some other way still converges.
root_a_start=$(part_start "$PART_ROOT_A")
root_a_end=$(part_end "$PART_ROOT_A")
boot_b_start=$(part_start "$PART_BOOT_B")

if (( root_a_end + 1 < boot_b_start )); then
    log "growing rootA to $(human $(( boot_b_start - root_a_start )))"
    # -N edits one partition entry and leaves the others alone. The start is
    # passed back unchanged so the filesystem stays exactly where it is.
    echo "start=${root_a_start}, size=$(( boot_b_start - root_a_start ))" \
        | sfdisk --no-reread --no-tell-kernel -N "$PART_ROOT_A" "$DISK" >/dev/null
    partx -u "$DISK"
    ok "rootA partition is now $(human "$(blockdev --getsz "$DEV_ROOT_A")")"
else
    skip "rootA already reaches bootB"
fi

# ext4 grows online, so this works on the root filesystem we are running from.
if out=$(resize2fs "$DEV_ROOT_A" 2>&1); then
    if [[ "$out" == *"Nothing to do"* ]]; then
        skip "rootA filesystem already fills its partition"
    else
        ok "rootA filesystem grown to $(findmnt -no SIZE /)"
    fi
else
    die "could not grow the rootA filesystem: $out"
fi
