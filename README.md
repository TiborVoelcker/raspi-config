# Raspberry Pi Provisioning

This repository holds a modular [cloud-init](https://cloud-init.io/) configuration for
my Raspberry Pi, applied on first boot. Instead of one big config file baked into every
SD card, the setup is split into small modules under `modules/` that get merged together
via cloud-init's `#include` mechanism - see `AGENTS.md` for how the pieces fit together.

## Setup

1. Write an image with the Raspberry Pi Imager as usual. In its OS customization
   options, set your hostname, user/password, SSH key, locale/timezone, and configure
   an internet connection (ethernet or Wi-Fi) - this is what will become your
   device-specific `base.yaml` module.
2. Once written, open the boot partition (`boot/firmware/`) on the SD card.
3. Create a `modules/` folder there and move the Imager-generated `user-data` into it,
   renaming it to `base.yaml` (so it ends up at `boot/firmware/modules/base.yaml`).
4. Copy this repository's root `user-data` file into `boot/firmware/`, replacing the
   file you just moved away in step 3. This is the file that actually includes
   `base.yaml` plus the shared modules from this repo.
5. **Don't forget:** open `boot/firmware/network-config` and set `optional` to `false`
   for whichever interface(s) you use (`eth0` and/or `wlan0`). The Imager leaves it as
   `true`, but cloud-init needs the network to be up before it can fetch the
   GitHub-hosted modules, so boot must wait for it.
6. Insert the SD card and boot the Pi.

## Adding a module

Drop a new cloud-config file into `modules/`, then add it to the `#include` list in
`user-data`:

- Shareable, no secrets -> reference it by raw GitHub URL, like `motd.yaml`.
- Device-specific -> reference it by local `file:///boot/firmware/modules/...` path,
  like `base.yaml`, and don't commit real values for it.
