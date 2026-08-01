# Usage

## The data disk

Format it yourself first - the scripts never format anything:

```bash
sudo mkfs.ext4 -L homelab-data /dev/sdXN
```

**ext4 specifically.** exFAT and NTFS cannot store Unix ownership, which
container volumes need.

`02-data.sh` adds an fstab entry by UUID (never `/dev/sda1` - device letters
shift with enumeration order), with `nofail` so the Pi still boots without the
disk, and installs a systemd drop-in so Docker refuses to start unless `/data`
is mounted *and* carries its marker file.

That guard matters more than it looks. Without it, an absent disk means bind
mounts silently create empty directories under `/data`; Paperless finds no
database, concludes it is a fresh install, and initialises one on the SD card
while your real documents sit untouched on the unmounted disk. With it, the
system boots, the stack refuses to start, and you get an obvious error.

### Hardware notes

- **SSD over spinning disk.** A bus-powered HDD can exceed the Pi's USB budget
  and drop out under load. Otherwise use a powered hub.
- **Check your USB-SATA bridge.** Some enclosures misbehave with UAS on the Pi
  and can corrupt data. If yours is on a known-bad list, apply the matching
  `usb-storage.quirks` workaround in `cmdline.txt`.
- **A separate disk is not a backup.** It protects against SD card failure and
  makes resets safe. It does nothing about the disk itself failing. Set up
  restic or borg pushing `/data` somewhere else on a schedule.

## Before first boot - the one manual step

The baseline partitions are carved from **unallocated space at the end of the
card**. ext4 can be grown online but never shrunk, so if Raspberry Pi OS
auto-expands the root partition on first boot that space is gone for good.

Flash with Raspberry Pi Imager as usual (customisation is fine), then
**before the first boot** mount the small FAT partition on your laptop and
delete the `resize` token from `cmdline.txt` - the one near the end here:

```
console=serial0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait resize cfg80211.ieee80211_regdom=DE
```

Leave the rest of the line alone. Imager's own customisation is applied through
`custom.toml` and keeps working. Anything baked into the line itself, like the
`cfg80211.ieee80211_regdom=DE` above, is a real setting and must stay.

Check afterwards with `lsblk` that `p2` is roughly image-sized rather than
card-sized.

If you forget, `install.sh` refuses to touch the partition table and tells you
to re-image rather than improvising.

## Install

```bash
git clone <this-repo> ~/raspi-homelab
cd ~/raspi-homelab
sudo ./install.sh
```

Re-run any time. Every module no-ops where its work is already done, so adding
a module and re-running only does the new work.

**Run it early.** `01-create-baseline.sh` captures the baseline from whatever state the
system is in at that moment, and never recaptures. Running `install.sh` on a
freshly flashed card gives you a clean baseline; running it for the first time
on a Pi you have been using for six months bakes those six months in
permanently.

## Day to day

```bash
sudo homelab-status          # partitions, data disk, baseline age, armed?
sudo homelab-reset           # wipe live, overwrite with baseline
```

Recovery is always the same two steps:

```bash
sudo homelab-reset           # reboots twice, lands on the pristine system
sudo ./install.sh            # rebuilds the homelab on top
```

`homelab-reset` shows when the baseline was captured and asks for confirmation
before it arms anything. It refuses outright if there is no baseline.

After a reset, `02-data.sh` asks you to pick the data disk again - the reset
system has no `/data` fstab entry, just like a freshly flashed card. Your
documents are untouched on the disk; only the fstab line is rebuilt. Set
`HOMELAB_DATA_UUID` to skip the prompt:

```bash
sudo HOMELAB_DATA_UUID=<uuid> ./install.sh
```

### Recapturing the baseline

Normally you never do this. But the baseline is never apt-upgraded, so after a
Debian major release upgrade it can be old enough that its apt sources no
longer resolve - at which point a reset lands you somewhere `install.sh` cannot
build on.

To recapture, delete the stamp and re-run on a system you would be happy to
start from:

```bash
sudo mount /dev/mmcblk0p4 /mnt
sudo rm /mnt/etc/homelab-baseline /mnt/etc/homelab-role
sudo umount /mnt
sudo ./install.sh
```

Whatever is on the live system at that moment becomes the new baseline, so do
it from a system that is as close to freshly-flashed as you can manage.

### Safety gates on a reset

`homelab-reset-main` runs on every baseline boot and refuses to do anything unless
**all three** hold:

1. `/etc/homelab-role` says `baseline` - we are not the live system
2. this boot came via tryboot - it was deliberate
3. the arm marker exists on bootB - a reset was actually requested

`homelab-reset` sets up all three: the baseline carries its role from when it
was captured, and reset arms the marker and then triggers the tryboot itself.

The marker lives on **bootB**, not bootA. Each system mounts its own boot
partition, so a marker on bootA would be invisible to the baseline;
`arm_reset()` in `lib/common.sh` mounts bootB explicitly to place it.

To disarm by hand - say a reset failed partway and you want to stop it
retrying:

```bash
sudo mount /dev/mmcblk0p3 /mnt && sudo rm /mnt/homelab-reset.arm && sudo umount /mnt
```

## Looking at the baseline

Mount it from the live system rather than booting it:

```bash
sudo mount /dev/mmcblk0p4 /mnt      # rootB
sudo mount /dev/mmcblk0p3 /mnt/boot/firmware
```

Booting it directly is safe - without an arm marker the reset service exits
immediately.

## Watching a reset

The baseline keeps the live system's hostname, address and SSH host keys, so
you can log in while it works:

```bash
sudo tail -f /boot/firmware/homelab-reset.log
```

The rootfs copy reports progress, so that line moves. Your session drops when
it finishes and reboots - that is how you know it is done.

`journalctl -u homelab-apply-reset -f` shows the same output, except for the
progress, which has no line breaks for the journal to split on and so arrives
all at once at the end.

Afterwards the log is on bootB, which the live system does not mount:

```bash
sudo mount /dev/mmcblk0p3 /mnt && cat /mnt/homelab-reset.log
```

The reset before it is kept alongside as `homelab-reset.log.prev`. These are
the first place to look if a reset did not do what you expected.

## Things to keep in mind

**Service data belongs on `/data`.** Anything under `/opt` or `/var/lib` is in
the reset scope and gets rolled back. `20-paperless.sh` shows the split: config
in `/opt`, state in `/data`.

**A reset goes all the way back to the flashed image**, not to yesterday. If
you want "the state I had last Tuesday", this is the wrong tool - back up
`/data` and keep your changes in `install.sh`.

**Keep one physical spare.** This protects against a broken system, not dead
hardware. A second SD card with a known-good image in a drawer is the actual
disaster recovery answer.

## Test order

Do all of this before trusting it with anything:

1. `sudo ./install.sh` on a freshly-imaged, not-yet-auto-expanded card. Check
   `homelab-status` looks sane.
2. Plain `sudo reboot` - confirm you land back on the live system
   automatically. This proves the tryboot fail-safe independent of anything
   specific to this repo. **Don't skip to step 3.**
3. Only then: make a throwaway change (touch a file, install a package),
   `sudo homelab-reset`, confirm it reboots, resets, and reboots back - and
   that the throwaway change is gone while `/data` survived.
4. `sudo ./install.sh` again and confirm you get the working homelab back. This
   is the half that makes a reset survivable, so test it as deliberately as the
   reset itself.

## Adding a service

Copy `modules/20-paperless.sh`:

- directories on `/data` so a reset preserves them
- upstream config fetched once, guarded by a file test
- secrets generated once - regenerating orphans existing data
- `docker compose up -d` unguarded; Compose reconciles state itself

Most install instructions paste in nearly verbatim. Only lines that would be
destructive to repeat need a guard.
