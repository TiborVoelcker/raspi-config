# Agent notes

Context for whoever (human or AI) picks this repo up next.

## What this is

Configuration for provisioning my Raspberry Pi via [cloud-init](https://cloud-init.io/)
on first boot, driven by the Raspberry Pi Imager. The goal is to stop hand-configuring
each new SD card and instead keep the setup in version control, split into small,
composable pieces instead of one monolithic cloud-config file.

## How it's wired together

cloud-init supports merging multiple config files together via `#include`. That's the
whole mechanism this repo relies on:

- `user-data` (repo root) is what ends up as `/boot/firmware/user-data` on the SD card.
  It contains nothing but an `#include` directive listing the modules to merge, in order:
  - `file:///boot/firmware/modules/base.yaml` - loaded from the boot partition itself.
  - `https://raw.githubusercontent.com/.../modules/motd.yaml` - fetched straight from
    this repo on GitHub during first boot.
- `modules/` holds one cloud-config snippet per concern.
  - `base.yaml` is device-specific (user account, password hash, SSH key, timezone,
    hostname, ...), so it's never fetched from GitHub and never committed with real
    values - only a placeholder stub lives here. See `README.md` for how to produce
    the real one per device.
  - Everything else here has no secrets, so it's referenced by raw GitHub URL and
    shared across every Pi that includes this repo's `user-data`.
- `includes/` holds plain files referenced by a module via `source: uri:` (e.g.
  `modules/motd.yaml` points at `includes/motd_updates`), for content that isn't
  itself cloud-config YAML.

## Current status / plan

- [x] Base include chain works (`user-data` -> local `base.yaml` + remote `motd.yaml`).
- [x] MOTD module (`modules/motd.yaml`): shows upgradable package count on login.
- [ ] `modules/base.yaml` is a stub only - fill in per device, don't commit real values.
- [ ] Add further modules as needed, one file per concern, in `modules/`. Wire a new
      one up by adding another line to the `#include` list in `user-data` (raw GitHub
      URL if it's shareable, local `file://` path if it must stay device-specific like
      `base.yaml`).
- Dropped the old `imager_files/` directory (a redacted snapshot of what the
  Raspberry Pi Imager used to generate) now that `modules/base.yaml` covers that role
  as a proper template within the module structure.
