#!/usr/bin/env bash
# Upgrade the OS.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
ok "system upgraded"

if [[ -f /run/reboot-required ]]; then
    warn "reboot required to finish the upgrade"
fi
