#!/usr/bin/env bash
# Install Claude Code for the account that ran install.sh.
#
# The one place in the repo that pipes curl into a shell: there is no Debian
# package, and the npm package needs Node 22 where trixie ships 20. The
# installer works per-home rather than system-wide, so it runs as $SUDO_USER -
# root would get its own copy in /root, which is not the one you type `claude`
# at.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd curl

# Optional tooling: a missing $SUDO_USER should not abort provisioning.
user="${SUDO_USER:-}"
if [[ -z "$user" || "$user" == root ]]; then
    warn "no SUDO_USER - skipping claude code (run install.sh with sudo from your own account)"
    exit 0
fi

# A login shell, so ~/.profile has put ~/.local/bin on PATH the same way it
# will when you log in.
if sudo -u "$user" -H bash -lc 'command -v claude' >/dev/null 2>&1; then
    skip "claude code already installed for $user"
    exit 0
fi

log "installing claude code for $user"
# pipefail inside the inner shell too: without it a failed download reports
# success, because the exit status is bash's after reading nothing at all.
sudo -u "$user" -H bash -lc \
    'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash' \
    || die "the claude code installer failed"

sudo -u "$user" -H bash -lc 'command -v claude' >/dev/null 2>&1 \
    || die "claude is not on $user's PATH after installing - open a new shell and check ~/.local/bin"

ok "installed claude code for $user"
