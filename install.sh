#!/usr/bin/env bash
# One command to converge this Pi to the state described by this repo.
# Safe to re-run: every module no-ops when its work is already done.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/lib/common.sh"

need_root

if [[ "$(current_role)" == "rescue" ]]; then
    die "this is the rescue system - do not provision from here (see README)"
fi

log "raspi-homelab provisioning"
echo "    disk modules run first; service modules after"
echo

for module in "$REPO_DIR"/modules/*.sh; do
    [[ -e "$module" ]] || continue
    name=$(basename "$module")
    log "$name"
    REPO_DIR="$REPO_DIR" bash "$module"
    echo
done

log "installing helper commands"
for helper in "$REPO_DIR"/bin/*; do
    [[ -f "$helper" ]] || continue
    name=$(basename "$helper")
    ln -sfn "$helper" "/usr/local/sbin/$name"
    ok "$name -> /usr/local/sbin/$name"
done

echo
ok "done"
echo
echo "  homelab-checkpoint   snapshot this system onto the rescue partition"
echo "  homelab-reset        wipe this system back to the last checkpoint"
echo "  homelab-status       show partition + checkpoint state"
