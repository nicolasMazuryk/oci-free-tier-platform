#!/usr/bin/env bash
# Push host/common + host/<vm> to /opt/core on the VM and re-run bootstrap.sh.
# /opt/core/core.env (rendered by Terraform) is left untouched.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/bastion.sh"
vm="${1:-app}"; ssh_opts "$vm"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -R "$REPO_ROOT/host/common/." "$REPO_ROOT/host/$vm/." "$stage/"
log "syncing host/$vm -> $vm:/opt/core"
rsync -az --delete --exclude core.env -e "ssh $(printf '%q ' "${SSH_OPTS[@]}")" "$stage/" "$TARGET:/tmp/core-sync/"
ssh "${SSH_OPTS[@]}" "$TARGET" 'sudo rsync -a --exclude core.env /tmp/core-sync/ /opt/core/ && rm -rf /tmp/core-sync && sudo bash /opt/core/bootstrap.sh'
