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

This only runs `modules/` (storage, data disk, rescue system) - it does
**not** touch `services/`. That's deliberate: it leaves you with a plain,
service-free system whose first rescue snapshot (taken right here, by
`modules/05-rescue.sh`) is a genuine fail-safe, not a copy of whatever
services happened to be installed at the time. Take the chance to update and
poke at the system, then lock that baseline in:

```bash
sudo apt update && sudo apt upgrade
sudo homelab-checkpoint
```

Only once you're happy with that baseline, layer services on top:

```bash
sudo ./install.sh --services
```

Re-run either form any time - every module and service no-ops where its work
is already done, so adding one and re-running only does the new work.

Note: `install.sh`'s closing banner mentions `homelab-status` and
`homelab-reset` - those commands don't exist yet (see `AGENTS.md`). Only
`homelab-checkpoint` is currently installed into `/usr/local/sbin`.

## Day to day (today)

```bash
sudo homelab-checkpoint      # snapshot live -> rescue. live, no reboot
```

Checkpointing runs live because the rescue partitions aren't in use while
you're on the live system. Restoring needs a reboot into rescue, because you
can't overwrite the filesystem you're currently running from - that
asymmetry is inherent, not a design choice.

`homelab-status`, `homelab-reset`, and `homelab-rescue-shell` are planned but
not written yet - see `AGENTS.md` for the current status.

### Safety gates on restore

`homelab-restore` (installed into the rescue system, run by
`rescue/homelab-restore.service` at boot) refuses to do anything unless
**all three** hold:

1. `/etc/homelab-role` says `rescue` - we are not the live system
2. this boot came via tryboot - it was deliberate
3. the arm marker exists on bootB - a restore was actually requested

Gate 3 is why a future `homelab-rescue-shell` would be safe: it would clear
the marker, so you can inspect the rescue system without it overwriting the
live one on its next boot.

Note that the marker lives on **bootB**, not bootA. Each system mounts its
own boot partition, so a marker on bootA would be invisible to the rescue
system. `arm_restore()` in `lib/common.sh` mounts bootB explicitly to place
it - there's just no command wired up to call it yet.

## Things to keep in mind

**Don't do real work from the rescue system.** It's a snapshot, not a second
machine. Drift there quietly redefines what a reset restores to.

**Service data belongs on `/data`.** Anything under `/opt` or `/var/lib` is in
the reset scope and gets rolled back. The pattern in `20-paperless.sh` shows
the split: config in `/opt`, state in `/data`.

**There's no uninstall.** Removing or editing a file in `services/` doesn't
undo what it already did to the live system. If a service turns out broken,
or you just don't want it anymore, restoring the pre-services checkpoint
(the one you made right after `install.sh`, before ever running
`--services`) is the only sure way back to zero.

**Keep one physical spare.** This protects against a broken system, not dead
hardware. A second SD card with a known-good image in a drawer is the actual
disaster recovery answer.

## Test order (current scope: initial setup + checkpoint only)

The reset/rescue-shell round trip can't be fully exercised yet since those
commands don't exist - `arm_restore`/tryboot would have to be triggered by
hand. For now:

1. `sudo ./install.sh` on a freshly-imaged, not-yet-auto-expanded card.
   Eyeball the result yourself (`lsblk`, `findmnt /data`, `systemctl status
   docker`) - there's no `homelab-status` yet to do this for you. Confirm
   nothing under `services/` ran (e.g. no Paperless containers, no
   `/opt/paperless`).
2. `sudo homelab-checkpoint`. Confirm it completes, and that the rescue
   partitions (`p3`/`p4`) now hold a copy of the system (mount them
   read-only and look, or trust the "checkpoint written" timestamp). This
   is your service-free fail-safe - worth confirming it really is one.
3. Plain `sudo reboot` - confirm you land back on the live system
   automatically. This proves the tryboot fail-safe (an ordinary reboot
   never lands on rescue) independent of anything specific to this repo.
4. Only then: `sudo ./install.sh --services`, confirm the service(s) come up.

Don't attempt a real restore round trip yet - that needs
`homelab-rescue-shell`/`homelab-reset` (or manually arming + triggering
tryboot) and hasn't been exercised end-to-end.

## Adding a service

Copy `services/20-paperless.sh`:

- directories on `/data` so a reset preserves them
- upstream config fetched once, guarded by a file test
- secrets generated once - regenerating orphans existing data
- `docker compose up -d` unguarded; Compose reconciles state itself

Most install instructions paste in nearly verbatim. Only lines that would be
destructive to repeat need a guard.
