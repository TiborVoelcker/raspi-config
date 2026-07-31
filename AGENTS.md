# Agent notes

Context for whoever (human or AI) picks this repo up next. Keep it reflecting
current reality, not the day it was written. Each script's own header comment
explains what that script does; this file covers what you cannot see from
inside a single file.

## What we're trying to achieve

Reproducible, script-driven provisioning for a Raspberry Pi homelab, plus a
self-hosted "reset button": if the live system gets into a bad state, put back
a pristine copy of the flashed OS - no second computer, no fresh SD card, no
physical access beyond a reboot.

The design rests on one decision: **`install.sh` is the only thing that defines
the desired state.** Everything it builds is disposable, because it can be
rebuilt. That makes the recovery story a single path rather than a matrix:

```
bad state -> homelab-reset -> pristine baseline -> install.sh -> working homelab
fresh card                 -> pristine baseline -> install.sh -> working homelab
```

Those two rows must stay interchangeable. Anything that makes a restored system
differ from a freshly flashed one is a bug.

Two mechanisms make it work:

1. **Convergent provisioning.** `install.sh` runs small idempotent modules in
   lexicographic order. Each either does its job or no-ops, so re-running after
   adding a module only does the new work.
2. **A baseline on its own partitions**, carved out of unallocated space at the
   end of the SD card and reached through the firmware's `tryboot` mechanism.
   Its own boot partition means a kernel upgrade on the live system can never
   disturb it.

Service state (Paperless documents, databases) lives on a **separate external
disk**, so a reset never touches it.

## What the baseline is, and is not

It is a copy of the system **exactly as it came off the SD card image**,
captured once by `01-rescue.sh` before any other module runs, then left alone
forever. No `/data` mount, no apt upgrade, no Docker, no services.

It is **not** a snapshot of a working system, and there is deliberately no way
to refresh it. That rules out a whole category of problems: it cannot drift, it
cannot accumulate the breakage you are trying to escape, and there is no
"which checkpoint am I restoring?" question to get wrong.

Consequences worth knowing:

- Nothing needs to be made inert in the baseline. Docker is not masked there
  because Docker was never installed there.
- A reset genuinely removes everything - packages, containers, config under
  `/opt`. That is intended. `install.sh` puts it back.
- The baseline is never apt-upgraded, so it ages. `03-upgrade.sh` runs on every
  `install.sh`, so the system you end up on is current regardless.
- The baseline is booted only to run the restore. It is not a place to work,
  and nothing is invested in making it pleasant. To inspect or change it,
  mount `p4` from the live system.

## How it's wired together

### Partition layout (MBR, four primaries, no extended container)

```
p1  FAT32  bootA   live system's boot partition, holds autoboot.txt
p2  ext4   rootA   live system
p3  FAT32  bootB   baseline's OWN boot partition
p4  ext4   rootB   baseline
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

`autoboot.txt` (on bootA) drives the switch between live and baseline:

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

The restore has to boot into the baseline because you cannot rsync over the
filesystem you are running from. That asymmetry is inherent, not a feature: it
is the only reason the baseline needs to be bootable at all.

### Repo layout

| Path | Role |
| --- | --- |
| `install.sh` | Entry point: runs `modules/*.sh` in order, then symlinks `bin/` into `/usr/local/sbin`. |
| `lib/common.sh` | Sourced by everything, including `restore.sh` inside the baseline. Output helpers, guards, layout constants, copy primitives. |
| `modules/00-storage.sh` | Carves `p3`/`p4` out of unallocated space. |
| `modules/01-rescue.sh` | Captures the baseline onto `p3`/`p4`, once; writes `autoboot.txt`. |
| `modules/02-data.sh` | Mounts the external disk at `/data` by UUID; makes Docker refuse to start unless it is genuinely mounted. |
| `modules/03-upgrade.sh` | `apt-get update && upgrade`. |
| `modules/11-docker.sh` | Docker Engine + Compose plugin from Debian's repos. |
| `modules/20-paperless.sh` | The only service module so far, and the template for the rest. |
| `bin/homelab-reset` | Arms the restore and triggers a tryboot. |
| `bin/homelab-status` | Read-only snapshot: role, tryboot, partitions, `/data`, baseline age, armed? |
| `rescue/restore.sh` | Installed into the baseline as `/usr/local/sbin/homelab-restore`. Overwrites `p1`/`p2` with itself, behind three gates. |
| `rescue/homelab-restore.service` | Runs `restore.sh` at boot on the baseline. |

**Module numbering is load-bearing.** `01-rescue.sh` captures the baseline, so
everything numbered after it is by definition absent from that baseline. A new
module that must survive a reset does not exist - put its state on `/data`
instead.

### The capture/restore pair

`01-rescue.sh` makes only three changes to the clone: retarget its fstab at
p3/p4, write `rescue` to the role file, and install the restore machinery.
`rescue/restore.sh` undoes exactly those on the way back, plus the cmdline.
**Change one and check the other** - an edit with no inverse is silently
inherited by the restored live system.

That list is short by design. Every entry on it is a way the baseline differs
from a freshly flashed card, which is precisely what the two rows at the top of
this file promise not to happen.

## Current status

Everything above is implemented. Nothing has been exercised on real hardware
yet; `USAGE.md`'s "Test order" is the sequence to do that with, and step 3 is
the one that must not be skipped.

## Things to watch for when extending this

- New service modules follow `20-paperless.sh`: state on `/data`, everything
  else treated as disposable by a reset.
- Never regenerate a secret that already exists on disk - that orphans whatever
  data was encrypted or keyed with the old one.
- Resist adding anything to the baseline. Every addition is a way a restored
  system can differ from a freshly flashed one, and the value of this design is
  that those two are the same thing.
- `restore.sh` runs from a copy of `lib/common.sh` installed at
  `/usr/local/lib/homelab/common.sh`. A new `common.sh` helper that assumes it
  is running on the live system will break the restore side.
