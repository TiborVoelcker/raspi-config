#!/usr/bin/env bash
# Upgrade the OS.
#
# Numbered AFTER 01-create-baseline.sh: the baseline matches the flashed image, which is
# not upgraded either. Since this runs on every install.sh, a reset followed by
# install.sh lands on an up-to-date system however old the baseline is.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

apt_quiet update

# Counted from a dry run so there is something to report, since the upgrade
# itself prints nothing.
pending=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)

if (( pending == 0 )); then
    skip "already up to date"
else
    log "upgrading $pending packages - no output until it finishes"
    apt_quiet upgrade
    ok "upgraded $pending packages"
fi

if [[ -f /run/reboot-required ]]; then
    warn "reboot required to finish the upgrade"
fi
