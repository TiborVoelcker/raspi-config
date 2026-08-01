#!/usr/bin/env bash
# Install Docker Engine + the Compose plugin from Debian's own repos - no
# third-party apt source or curl-pipe-to-shell needed.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    skip "docker and the compose plugin already installed"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y docker.io docker-compose
    ok "installed docker.io + docker-compose"
fi

# Service modules all use `docker compose`, so the plugin has to be wired in.
# A package providing only a standalone docker-compose binary would install
# cleanly and then fail in 20-paperless.sh instead of here.
docker compose version >/dev/null 2>&1 \
    || die "'docker compose' is not available - the installed compose package does not provide the CLI plugin"

systemctl enable --now docker >/dev/null
ok "docker running"
