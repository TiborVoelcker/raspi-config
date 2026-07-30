# Usage

## The data disk

Format it yourself first - the scripts never format anything:

```bash
sudo mkfs.ext4 -L homelab-data /dev/sdXN
```

**ext4 specifically.** exFAT and NTFS cannot store Unix ownership, which
container volumes need.

`01-data.sh` adds an fstab entry by UUID (never `/dev/sda1` - device letters
shift with enumeration order), with `nofail` so the Pi still boots without the
disk, and installs a systemd drop-in so Docker refuses to start unless `/data`
is mounted *and* carries the marker file.

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

The rescue partitions are carved from **unallocated space at the end of the
card**. ext4 can be grown online but never shrunk, so if Raspberry Pi OS
auto-expands the root partition on first boot that space is gone for good.

Flash with Raspberry Pi Imager as usual (customisation is fine), then
**before the first boot** mount the small FAT partition on your laptop and
delete this token from `cmdline.txt`:

```
init=/usr/lib/raspberrypi-sys-mods/firstboot
```

Leave the rest of the line alone - Imager's own customisation runs through a
separate `systemd.run=` mechanism and keeps working. Check afterwards that
`p2` is roughly image-sized rather than card-sized:

```bash
lsblk
```

If you forget, `install.sh` refuses to touch the partition table and tells
you to re-image rather than improvising.

## Install

```bash
git clone <this-repo> ~/raspi-homelab
cd ~/raspi-homelab
sudo ./install.sh
```

Re-run any time. Every module no-ops where its work is already done, so
adding a module and re-running only does the new work.

## Day to day

```bash
sudo homelab-status          # partitions, data disk, checkpoint age, armed?
sudo homelab-checkpoint      # snapshot live -> rescue. live, no reboot
sudo homelab-reset           # wipe live, restore from last checkpoint
```

Checkpointing runs live because the rescue partitions aren't in use while
you're on the live system. Restoring needs a reboot into rescue, because you
can't overwrite the filesystem you're currently running from - that
asymmetry is inherent, not a design choice. `homelab-reset` shows you the
checkpoint's timestamp and asks for confirmation before it arms anything -
read that timestamp, it's the only preview you get of what you're about to
lose.

`homelab-rescue-shell` (boot into rescue *without* committing to a restore,
just to look around) is still planned but not written - see `AGENTS.md`.

### Safety gates on restore

`homelab-restore` (installed into the rescue system, run by
`rescue/homelab-restore.service` at boot) refuses to do anything unless
**all three** hold:

1. `/etc/homelab-role` says `rescue` - we are not the live system
2. this boot came via tryboot - it was deliberate
3. the arm marker exists on bootB - a restore was actually requested

`homelab-reset` is what sets up all three: it triggers the tryboot itself
(gate 2) after arming the marker (gate 3), and the rescue system already
carries the `rescue` role from when it was cloned (gate 1). Gate 3 is why a
future `homelab-rescue-shell` would be safe: it would boot into rescue
*without* arming, so you could inspect it without risking an overwrite on
its next boot.

Note that the marker lives on **bootB**, not bootA. Each system mounts its
own boot partition, so a marker on bootA would be invisible to the rescue
system. `arm_restore()` in `lib/common.sh` (called by `homelab-reset`)
mounts bootB explicitly to place it.

## Things to keep in mind

**Don't do real work from the rescue system.** It's a snapshot, not a second
machine. Drift there quietly redefines what a reset restores to.

**Service data belongs on `/data`.** Anything under `/opt` or `/var/lib` is in
the reset scope and gets rolled back. The pattern in `20-paperless.sh` shows
the split: config in `/opt`, state in `/data`.

**Keep one physical spare.** This protects against a broken system, not dead
hardware. A second SD card with a known-good image in a drawer is the actual
disaster recovery answer.

## Test order

Do all of this before trusting it with anything:

1. `sudo ./install.sh` on a freshly-imaged, not-yet-auto-expanded card.
   Check `homelab-status` looks sane.
2. `sudo homelab-checkpoint`.
3. Plain `sudo reboot` - confirm you land back on the live system
   automatically. This proves the tryboot fail-safe (an ordinary reboot
   never lands on rescue) independent of anything specific to this repo.
4. Only then: make a throwaway change (touch a file, install a package),
   `sudo homelab-reset`, confirm it reboots, restores, and reboots back -
   and that the throwaway change is gone while `/data` survived.

Step 3 proves the fail-safe. Don't skip to step 4.

There's no `homelab-rescue-shell` yet to poke around the rescue system
*without* committing to a restore - right now, booting into rescue means a
restore either happens (if armed) or it doesn't (if not), nothing in
between beyond a normal shell.

## Adding a service

Copy `modules/20-paperless.sh`:

- directories on `/data` so a reset preserves them
- upstream config fetched once, guarded by a file test
- secrets generated once - regenerating orphans existing data
- `docker compose up -d` unguarded; Compose reconciles state itself

Most install instructions paste in nearly verbatim. Only lines that would be
destructive to repeat need a guard.
