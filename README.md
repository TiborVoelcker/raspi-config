# raspi-homelab

Convergent, script-driven provisioning for my Raspberry Pi homelab, plus a
self-hosted "reset button": re-image the card without taking it out of the Pi.
A pristine copy of the flashed OS lives on spare SD card space and can be put
back at any time - no second computer, no card reader, just a reboot. Service
data lives on a separate external disk, so a reset never touches it.

`install.sh` is the single source of truth for what this Pi should look like.
It runs small idempotent modules and is safe to re-run. Early on it captures a
**baseline** - the system exactly as it came off the SD card image - onto its
own pair of partitions, and never touches it again.

`homelab-reset` puts that baseline back. The result is equivalent to
re-flashing the card, so the recovery is always the same two steps: reset, then
re-run `install.sh`.

See `AGENTS.md` for the design and `USAGE.md` for setup and day-to-day
commands.
