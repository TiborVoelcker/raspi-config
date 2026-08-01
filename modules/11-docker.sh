#!/usr/bin/env bash
# Install Docker Engine + the Compose plugin from Debian's own repos - no
# third-party apt source or curl-pipe-to-shell needed.
#
# Like everything after 01-rescue.sh, this never reaches the baseline, so a
# reset removes Docker entirely and the next install.sh puts it back.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    skip "docker and the compose plugin already installed"
else
    apt_quiet update

    # An installable version, not just a name apt knows: `apt-cache show`
    # succeeds for virtual packages that cannot be installed at all.
    installable() {
        local candidate
        candidate=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}')
        [[ -n "$candidate" && "$candidate" != "(none)" ]]
    }

    # Debian has shipped the compose plugin under more than one package name,
    # so take whichever this release actually has rather than pinning one.
    compose_pkg=""
    for candidate in docker-compose-v2 docker-compose-plugin docker-compose; do
        if installable "$candidate"; then
            compose_pkg="$candidate"
            break
        fi
    done
    [[ -n "$compose_pkg" ]] || die "no docker compose package found in apt"

    apt_quiet install docker.io "$compose_pkg"
    ok "installed docker.io + $compose_pkg"
fi

# Service modules all use `docker compose`, so the plugin has to be wired in.
# A package providing only a standalone docker-compose binary would install
# cleanly and then fail in 20-paperless.sh instead of here.
docker compose version >/dev/null 2>&1 \
    || die "'docker compose' is not available - the installed compose package does not provide the CLI plugin"

systemctl enable --now docker >/dev/null
ok "docker running"
