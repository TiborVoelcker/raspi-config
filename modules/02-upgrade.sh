#!/usr/bin/env bash
# Upgrade the OS before the rescue system's first snapshot exists (see
# 05-rescue.sh), so that snapshot - and every reset it feeds - starts from
# an up-to-date system rather than whatever was on the card the day it was
# flashed.
#
# apt is already convergent, so this runs unconditionally every time
# install.sh does, same spirit as `docker compose up -d` in
# services/20-paperless.sh: no work needed once everything's current.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
ok "system upgraded"

if [[ -f /var/run/reboot-required ]]; then
    warn "reboot required to finish the upgrade - reboot before homelab-checkpoint"
fi
