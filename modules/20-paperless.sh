#!/usr/bin/env bash
# Example service module. The shape to copy for the rest of the stack:
#   1. directories on the DATA partition, so a reset preserves them
#   2. config from upstream, fetched once
#   3. secrets generated once, guarded
#   4. `docker compose up -d` - already idempotent, needs no guard
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

APP_DIR=/opt/paperless
DATA=/data/paperless

mkdir -p "$APP_DIR" "$DATA"/{data,media,export,consume}

if [[ -f "$APP_DIR/docker-compose.yml" ]]; then
    skip "compose file present"
else
    curl -fsSL -o "$APP_DIR/docker-compose.yml" \
      https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/main/docker/compose/docker-compose.sqlite.yml
    ok "fetched compose file"
fi

# Generate the secret exactly once - regenerating it would orphan existing data.
if [[ -f "$APP_DIR/docker-compose.env" ]]; then
    skip "env file present"
else
    cat > "$APP_DIR/docker-compose.env" <<EOF
PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
PAPERLESS_TIME_ZONE=Europe/Berlin
PAPERLESS_OCR_LANGUAGE=deu+eng
EOF
    chmod 600 "$APP_DIR/docker-compose.env"
    ok "generated env file"
fi

cd "$APP_DIR" && docker compose up -d
ok "paperless converged"
