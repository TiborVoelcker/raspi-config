#!/usr/bin/env bash
# One command to converge this Pi to the state described by this repo.
# Safe to re-run: every module no-ops when its work is already done.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/lib/common.sh"

need_root

if [[ "$(current_role)" == "rescue" ]]; then
    die "this is the baseline system - do not provision from here (see README)"
fi
echo main > "$ROLE_FILE"

log "raspi-homelab provisioning"
echo "    storage and the baseline first; everything else on top"
echo

# Before the modules, so homelab-status is on PATH to diagnose whichever one
# fails. They are symlinks into the repo, so they cost nothing and need no
# reinstalling when the repo is updated.
log "installing helper commands"
for helper in "$REPO_DIR"/bin/*; do
    [[ -f "$helper" ]] || continue
    name=$(basename "$helper")
    ln -sfn "$helper" "/usr/local/sbin/$name"
    ok "$name -> /usr/local/sbin/$name"
done
echo

for module in "$REPO_DIR"/modules/*.sh; do
    [[ -e "$module" ]] || continue
    name=$(basename "$module")
    log "$name"
    REPO_DIR="$REPO_DIR" bash "$module"
    echo
done

ok "done"
echo
echo "  homelab-reset        wipe this system back to the pristine baseline"
echo "  homelab-status       show partition + baseline state"
