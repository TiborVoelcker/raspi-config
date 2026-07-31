#!/usr/bin/env bash
# Upgrade the OS.
#
# Deliberately numbered AFTER 01-rescue.sh: the baseline is meant to match the
# flashed image, and a freshly flashed card is not upgraded either. Since this
# runs on every install.sh, a reset followed by install.sh lands on an
# up-to-date system regardless of how old the baseline is.
#
# Unguarded: apt is already convergent, so there is nothing to skip.
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
