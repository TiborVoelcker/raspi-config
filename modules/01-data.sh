#!/usr/bin/env bash
# Mount the external USB disk at /data, and make Docker refuse to start without
# it.
#
# The hazard: if the disk is absent but Docker starts anyway, bind mounts
# CREATE empty directories under /data. Paperless then sees no database,
# concludes it is a fresh install, and initialises one on the SD card while the
# real data sits untouched on the unmounted disk. Three layers stop that:
#   nofail            -> the Pi still boots without the disk, so you can SSH in
#   RequiresMountsFor -> Docker will not start until /data is genuinely mounted
#   marker file       -> catches "mounted, but it is the wrong disk"
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd lsblk blkid findmnt sfdisk
detect_disk

mkdir -p "$DATA_DIR"

# ---------- already configured? ----------
if grep -q "[[:space:]]${DATA_DIR}[[:space:]]" /etc/fstab; then
    skip "fstab already has $DATA_DIR"
    # Re-stash it even so: a restore reads this copy, and the line may predate
    # this module (added by hand, or by a version that never wrote the file).
    grep "[[:space:]]${DATA_DIR}[[:space:]]" /etc/fstab > "$DATA_FSTAB_SNIPPET"
else
    # Candidates: block devices that are not the SD card we booted from.
    mapfile -t candidates < <(
        lsblk -rno NAME,TYPE,SIZE,FSTYPE,LABEL \
            | awk '$2=="part"{print $1, $3, $4, $5}' \
            | grep -v "^$(basename "$DISK")"
    )

    if [[ -n "${HOMELAB_DATA_UUID:-}" ]]; then
        data_uuid="$HOMELAB_DATA_UUID"
    else
        [[ ${#candidates[@]} -gt 0 ]] \
            || die "no external partitions found - plug in the data disk and re-run"

        echo "  external partitions found:"
        for i in "${!candidates[@]}"; do
            printf '    [%d] %s\n' "$i" "${candidates[$i]}"
        done
        echo
        echo "  Pick the partition to mount at $DATA_DIR."
        echo "  This script never formats anything - format it yourself first with:"
        echo "      sudo mkfs.ext4 -L homelab-data /dev/sdXN"
        echo "  ext4 is required; exFAT and NTFS cannot store Unix ownership,"
        echo "  which container volumes need."
        echo
        read -rp "  index: " idx
        [[ "$idx" =~ ^[0-9]+$ && -n "${candidates[$idx]:-}" ]] || die "invalid selection"

        dev="/dev/$(echo "${candidates[$idx]}" | awk '{print $1}')"
        fstype=$(blkid -o value -s TYPE "$dev" || echo "")
        [[ "$fstype" == "ext4" ]] || die "$dev is '${fstype:-unformatted}', expected ext4"

        data_uuid=$(blkid -o value -s UUID "$dev")
        [[ -n "$data_uuid" ]] || die "could not read UUID of $dev"
    fi

    # UUID, never /dev/sdX - device letters shift with enumeration order.
    printf 'UUID=%s %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2\n' \
        "$data_uuid" "$DATA_DIR" > "$DATA_FSTAB_SNIPPET"
    cat "$DATA_FSTAB_SNIPPET" >> /etc/fstab

    systemctl daemon-reload
    ok "added $DATA_DIR to fstab (UUID=$data_uuid)"
fi

mountpoint -q "$DATA_DIR" || mount "$DATA_DIR" || die "could not mount $DATA_DIR"
ok "$DATA_DIR mounted from $(findmnt -no SOURCE "$DATA_DIR")"

[[ -f "$DATA_MARKER" ]] || { touch "$DATA_MARKER"; ok "wrote data marker"; }

# ---------- make Docker depend on the mount ----------
DROPIN=/etc/systemd/system/docker.service.d/10-homelab-data.conf
if [[ -f "$DROPIN" ]]; then
    skip "docker mount dependency present"
else
    mkdir -p "$(dirname "$DROPIN")"
    cat > "$DROPIN" <<EOF
[Unit]
RequiresMountsFor=$DATA_DIR

[Service]
ExecStartPre=/usr/bin/test -f $DATA_MARKER
EOF
    systemctl daemon-reload
    ok "docker will not start unless $DATA_DIR is mounted and verified"
fi
