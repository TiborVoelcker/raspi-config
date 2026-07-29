# raspi-homelab

Convergent, script-driven provisioning for my Raspberry Pi homelab, plus a
self-hosted "reset button": a fully independent rescue system living on spare
SD card space that can restore the live system at any time, no other computer
required. Service data lives on a separate external disk, so a reset never
touches it.

Roughly: `install.sh` runs small idempotent modules to set up storage, the
rescue partitions and each service; `homelab-checkpoint` snapshots the live
system onto the rescue partitions whenever you're happy with its state; a
reboot into the rescue system can then restore from that snapshot.

See `AGENTS.md` for the full design and current implementation status, and
`USAGE.md` for setup and day-to-day commands.
