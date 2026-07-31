# Agent notes

Context for whoever (human or AI) picks this repo up next. Keep it reflecting
current reality, not the day it was written. Each script's own header comment
explains what that script does; this file covers what you cannot see from
inside a single file.

## What we're trying to achieve

Reproducible, script-driven provisioning for a Raspberry Pi homelab, plus a
self-hosted "reset button": if the live system gets into a bad state, reboot
into a fully independent rescue copy and restore from it - no second computer,
no fresh SD card, no physical access beyond a reboot.

Two ideas make that possible:

1. **Convergent provisioning.** `install.sh` runs small idempotent modules in
   lexicographic order. Each either does its job or no-ops, so re-running after
   adding a module only does the new work.
2. **A fully independent rescue system**, carved out of unallocated space at
   the end of the SD card and reached through the firmware's `tryboot`
   mechanism. Its own boot partition means a kernel upgrade on the live system
   can never disturb it.

Service state (Paperless documents, databases) lives on a **separate external
disk**, so a reset never touches it.

## How it's wired together

### Partition layout (MBR, four primaries, no extended container)

```
p1  FAT32  bootA   live system's boot partition, holds autoboot.txt
p2  ext4   rootA   live system
p3  FAT32  bootB   rescue system's OWN boot partition
p4  ext4   rootB   rescue system
```

Plus a separate USB disk at `/data`. Putting `/data` on its own disk is what
frees the fourth MBR slot for rootB, and it keeps service data out of the reset
scope entirely.

Each system mounts *its own* boot partition at `/boot/firmware`. That is the
whole point of the layout: a kernel upgrade on one cannot touch the other's
kernel, overlays or cmdline.

`p3`/`p4` are carved from unallocated space at the end of the card, which is
why the card must **not** auto-expand `p2` on first boot - a mounted ext4
filesystem cannot be shrunk, so this has to be handled before the first boot,
not fixed up after. See `USAGE.md`, "Before first boot".

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
level rather than by swapping individual files. The tryboot flag is one-shot
and cannot be set by a cold boot, so an ordinary reboot or a power cut always
lands back on bootA with no action needed - that's the fail-safe the whole
design leans on.

### Repo layout

| Path | Role |
| --- | --- |
| `install.sh` | Entry point: runs `modules/*.sh` in order, then symlinks `bin/` into `/usr/local/sbin`. |
| `lib/common.sh` | Sourced by everything, including `restore.sh` inside the rescue system. Output helpers, guards, layout constants, clone/restore primitives. |
| `modules/00-storage.sh` | Carves `p3`/`p4` out of unallocated space. |
| `modules/01-data.sh` | Mounts the external disk at `/data` by UUID; makes Docker refuse to start unless it is genuinely mounted. |
| `modules/02-upgrade.sh` | `apt-get update && upgrade`, before the first rescue snapshot exists. |
| `modules/05-rescue.sh` | First-time clone onto `p3`/`p4`; writes `autoboot.txt`. |
| `modules/11-docker.sh` | Docker Engine + Compose plugin from Debian's repos. |
| `modules/20-paperless.sh` | The only service module so far, and the template for the rest. |
| `bin/homelab-checkpoint` | Re-syncs the live system onto the rescue partitions. This is what a reset restores to. |
| `bin/homelab-reset` | Arms the restore and triggers a tryboot. |
| `bin/homelab-status` | Read-only snapshot: role, tryboot, partitions, `/data`, checkpoint age, armed? |
| `rescue/restore.sh` | Installed into the rescue system as `/usr/local/sbin/homelab-restore`. Overwrites `p1`/`p2` with itself, behind three gates. |
| `rescue/homelab-restore.service` | Runs `restore.sh` at boot on the rescue system. |

Numeric prefixes carry meaning beyond ordering: `05-rescue.sh` takes the first
clone, so anything numbered after it (Docker, and every `20-` service module)
is absent from that first fail-safe baseline. Later checkpoints do copy Docker
across - it stays inert there because `finalise_rescue_system` masks it.

### The clone/restore pair

`finalise_rescue_system()` in `lib/common.sh` applies every rescue-specific
edit: fstab retarget, `/data` line removal, role, hostname, Docker mask,
restore-service install. `rescue/restore.sh` undoes exactly that list on the
way back. **They must be read and changed as a pair** - a rescue-specific edit
with no inverse is silently inherited by the restored live system.

Both `05-rescue.sh` (first clone) and `homelab-checkpoint` (every refresh) call
that one function rather than each carrying its own copy of the sequence. An
earlier version kept them duplicated, on the theory that side-by-side copies
make drift obvious; they sit in different files, they drifted anyway (a missing
rsync exclude), and nobody noticed.

## Current status

Everything above is implemented. Not built yet:

- [ ] `bin/homelab-rescue-shell` - boot into rescue *without* arming a restore,
      to look around safely. Today the only ways to see the rescue system are
      `homelab-reset` (which commits to a restore) or booting it by hand.

None of this has been exercised on real hardware yet. `USAGE.md`'s "Test order"
is the sequence to do that with, and step 3 is the one that must not be
skipped.

## Things to watch for when extending this

- New service modules follow `20-paperless.sh`: state on `/data`, everything
  else treated as disposable by a reset.
- Never regenerate a secret that already exists on disk - that orphans whatever
  data was encrypted or keyed with the old one.
- Any new rescue-specific edit needs its inverse in `rescue/restore.sh`.
- `restore.sh` runs from a copy of `lib/common.sh` installed at
  `/usr/local/lib/homelab/common.sh`. A new `common.sh` helper that assumes it
  is running on the live system will break the rescue side.
