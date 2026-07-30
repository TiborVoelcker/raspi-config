# Agent notes

Context for whoever (human or AI) picks this repo up next. Keep this file
updated as the design changes or modules get added - it's meant to reflect
current reality, not the day it was written.

## What we're trying to achieve

Reproducible, script-driven provisioning for a Raspberry Pi homelab, plus a
self-hosted "reset button": if the live system gets into a bad state, you can
reboot into a fully independent rescue copy and restore from it, without
needing a second computer, a fresh SD card, or physical access beyond a
reboot.

Two ideas make that possible:

1. **Convergent provisioning.** `install.sh` runs a set of small, idempotent
   modules. Each one either does its job or no-ops because the work is
   already done, so re-running `install.sh` after adding a module only does
   the new work.
2. **A fully independent rescue system**, carved out of unallocated space at
   the end of the SD card, using the Raspberry Pi firmware's `tryboot`
   mechanism. It has its own boot partition, so a kernel upgrade on the live
   system can never disturb it.

Service state (Paperless documents, database files, etc.) lives on a
**separate external disk**, not on the SD card, so a reset never touches it.

## How it's wired together

### Partition layout (MBR, four primaries, no extended container)

```
p1  FAT32  bootA   live system's boot partition, holds autoboot.txt
p2  ext4   rootA   live system
p3  FAT32  bootB   rescue system's OWN boot partition
p4  ext4   rootB   rescue system
```

Plus a separate USB disk, ext4, mounted at `/data`. Putting `/data` on its own
disk is what frees up the fourth MBR slot for the rescue root partition,
and it means a reset (which wipes/restores the SD card) never touches service
data at all.

Each system mounts *its own* boot partition at `/boot/firmware` - that is the
whole point of the layout: a kernel upgrade on one cannot touch the other's
kernel/overlays/cmdline.

`p3`/`p4` are carved from unallocated space at the end of the card by
`modules/00-storage.sh`, which is why the SD card must **not** be allowed to
auto-expand `p2` to fill the whole disk on first boot (see `USAGE.md`,
"Before first boot" - a mounted ext4 filesystem cannot be shrunk, so this has
to be handled before the first boot, not fixed up after).

### tryboot / autoboot.txt

`autoboot.txt` (on bootA) drives the switch between live and rescue:

```
[all]
tryboot_a_b=1
boot_partition=1

[tryboot]
boot_partition=3
```

`tryboot_a_b=1` makes the firmware read the ordinary `config.txt` from
whichever partition it lands on, so the switch happens at the *partition*
level (kernel, overlays, cmdline all come from bootB when tryboot fires), not
by swapping individual files. The tryboot flag is one-shot and cannot be set
by a cold boot, so an ordinary reboot or a power cut always lands back on
bootA with no action needed - that's the fail-safe the whole design leans on.

### Repo layout

- `install.sh` - entry point. Runs every `modules/*.sh` in lexicographic
  order (hence the numeric prefixes: disk/storage modules first, service
  modules after), then symlinks everything in `bin/` into `/usr/local/sbin`.
- `lib/common.sh` - sourced by `install.sh` and every module. Output helpers
  (`log`/`ok`/`skip`/`warn`/`die`), guards (`need_root`, `need_cmd`,
  `need_tryboot_support`), the partition-layout constants, `detect_disk`,
  and the rescue-boot helpers (`arm_restore`/`disarm_restore`/
  `restore_armed`) used to signal the rescue system that a restore was
  actually requested.
- `modules/00-storage.sh` - carves `p3`/`p4` out of unallocated space.
- `modules/01-data.sh` - finds/mounts the external data disk at `/data` by
  UUID, and makes `docker.service` refuse to start unless it's genuinely
  mounted (guards against Paperless-style silent data loss into an empty
  bind-mount directory - see the comment at the top of that file).
- `modules/05-rescue.sh` - first-time setup of the rescue partitions: clones
  the live boot+root onto `p3`/`p4`, retargets the clone's `fstab`/`cmdline`
  to its own partitions, marks its role as `rescue`, masks Docker there, and
  installs the restore service. Also writes `autoboot.txt`.
- `modules/20-paperless.sh` - the only service module so far, and the
  template for future ones: state on `/data` (survives a reset), config
  fetched from upstream once, secrets generated once (never regenerated -
  that would orphan existing data), `docker compose up -d` left unguarded
  since Compose already reconciles state.
- `bin/homelab-checkpoint` - re-syncs the live system onto the rescue
  partitions. Run this whenever the current state is one you'd be happy to
  return to; it's what a reset actually restores.
- `bin/homelab-reset` - shows the last checkpoint's timestamp, confirms,
  arms the restore (`arm_restore` in `lib/common.sh`), and triggers an
  immediate tryboot (`reboot "0 tryboot"`). Everything past that point
  happens inside the rescue system via `rescue/homelab-restore.service`.
- `bin/homelab-status` - read-mostly snapshot of where things stand: role,
  whether this boot was a tryboot, partition table, whether `/data` is
  mounted (and carries its marker), the rescue partition's last checkpoint
  timestamp, and whether a restore is currently armed.
- `rescue/restore.sh` - installed into the rescue system as
  `/usr/local/sbin/homelab-restore`. Runs on every rescue boot but is gated
  three ways, all of which must hold: role is `rescue`, this boot was a real
  tryboot (not the rescue system started some other way), and an "arm"
  marker file is present on the rescue boot partition. Only then does it
  overwrite the live system's `p1`/`p2` with itself and reboot back into it.
- `rescue/homelab-restore.service` - the systemd unit that runs
  `restore.sh` at boot. **Not part of the original design artifacts** - I
  wrote this myself since `05-rescue.sh`/`homelab-checkpoint` both install it
  but no content for it existed yet. It's a plain oneshot tied to
  `multi-user.target`, gated again with `ConditionPathExists` on the arm
  marker as a cheap first check. Review it - it's the one file here that
  hasn't been through the same scrutiny as the rest.

## Current status

Implemented and (structurally) reviewed:

- [x] `install.sh` + `lib/common.sh`
- [x] `modules/00-storage.sh`, `01-data.sh`, `05-rescue.sh`
- [x] `modules/20-paperless.sh` as the service-module template
- [x] `bin/homelab-checkpoint`
- [x] `bin/homelab-reset`
- [x] `bin/homelab-status`
- [x] `rescue/restore.sh`
- [x] `rescue/homelab-restore.service` (authored by me, needs a real look)

Deliberately not built yet:

- [ ] `bin/homelab-rescue-shell` - boot into rescue *without* arming a
      restore, to look around safely. Without it, the only way to inspect
      the rescue system today is `homelab-reset` itself (which commits to
      an actual restore) or booting it by hand and clearing the arm marker
      yourself.

`install.sh`'s closing banner (`homelab-checkpoint`/`homelab-reset`/
`homelab-status`) is now fully accurate. The full checkpoint -> reset round
trip can be exercised end-to-end; see `USAGE.md`'s "Test order".

## Things to watch for when extending this

- Any new service module should follow `20-paperless.sh`'s shape: state on
  `/data`, everything else treated as disposable by a reset.
- Anything that writes to *both* the live and rescue systems (like the
  restore-service install step) should stay duplicated between
  `05-rescue.sh` and `homelab-checkpoint` rather than factored into a shared
  function that only one of them calls with different mount points - keeping
  them textually side-by-side makes it obvious when one drifts from the
  other.
- Never regenerate a secret/credential that already exists on disk - that
  orphans whatever data was encrypted/keyed with the old one.
