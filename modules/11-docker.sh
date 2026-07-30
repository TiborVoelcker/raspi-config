#!/usr/bin/env bash
# Install Docker Engine + the Compose plugin from Debian's own repos - no
# third-party apt source or curl-pipe-to-shell needed. Raspberry Pi OS
# (Debian bookworm) ships packages recent enough for homelab use.
#
# Numbered to run AFTER 05-rescue.sh on purpose: the rescue system's first
# snapshot is taken before this module ever runs, so - like services/ -
# Docker never ends up on the fail-safe. See AGENTS.md.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

if command -v docker >/dev/null; then
    skip "docker already installed"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y docker.io docker-compose-v2
    ok "installed docker.io + docker-compose-v2"
fi

systemctl enable --now docker >/dev/null
ok "docker running"
