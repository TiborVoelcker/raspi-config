#!/usr/bin/env bash
# One command to converge this Pi to the state described by this repo.
# Safe to re-run: every module no-ops when its work is already done.
#
# `modules/` (storage, data disk, rescue system) always runs - it's what
# makes the rescue system exist in the first place. `services/` only runs
# when explicitly asked for with --services, so the rescue system's *first*
# snapshot (taken by modules/05-rescue.sh) is always a plain, service-free
# system - a real fail-safe to fall back to if a service turns out broken or
# you decide to remove it outright, rather than a snapshot of whatever
# happened to be installed at the time.
#
# Usual flow: `./install.sh`, update/check the system, `homelab-checkpoint`
# to lock that in, THEN `./install.sh --services` to layer services on top.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/lib/common.sh"

need_root

if [[ "$(current_role)" == "rescue" ]]; then
    die "this is the rescue system - do not provision from here (see README)"
fi

run_dir() {
    local dir="$1"
    for module in "$REPO_DIR"/"$dir"/*.sh; do
        [[ -e "$module" ]] || continue
        name=$(basename "$module")
        log "$name"
        REPO_DIR="$REPO_DIR" bash "$module"
        echo
    done
}

log "raspi-homelab provisioning"
echo "    modules (storage, data, rescue)"
echo

run_dir modules

if [[ "${1:-}" == "--services" ]]; then
    echo
    log "applying services"
    echo
    run_dir services
else
    echo
    skip "services/*.sh not applied - re-run with --services once you're happy with this baseline"
fi

echo
log "installing helper commands"
for helper in "$REPO_DIR"/bin/*; do
    [[ -f "$helper" ]] || continue
    target="/usr/local/sbin/$(basename "$helper")"
    ln -sfn "$helper" "$target"
    chmod +x "$helper"
    ok "$(basename "$helper") -> $target"
done

echo
ok "done"
echo
echo "  homelab-checkpoint   snapshot this system onto the rescue partition"
echo "  homelab-reset        wipe this system back to the last checkpoint"
echo "  homelab-status       show partition + checkpoint state"
