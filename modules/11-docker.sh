#!/usr/bin/env bash
# Install Docker Engine + the Compose plugin from Debian's own repos - no
# third-party apt source or curl-pipe-to-shell needed. Raspberry Pi OS
# (Debian bookworm) ships packages recent enough for homelab use.
#
# Like every module after 01-rescue.sh, this never reaches the baseline: the
# baseline is captured before Docker is installed and is never refreshed, so a
# reset removes Docker entirely and the next install.sh puts it back.
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
