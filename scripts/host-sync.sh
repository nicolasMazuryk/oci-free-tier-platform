#!/usr/bin/env bash
# Push host/common + host/<vm> to /opt/core on the VM and re-run bootstrap.sh.
# /opt/core/core.env (rendered by Terraform) is left untouched.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/bastion.sh"
vm="${1:-cloud}"; ssh_config "$vm"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -R "$REPO_ROOT/host/common/." "$REPO_ROOT/host/$vm/." "$stage/"
log "syncing host/$vm -> $vm:/opt/core"
rsync -az --delete --exclude core.env -e "ssh -F $SSH_CFG" "$stage/" "$SSH_HOST:/tmp/core-sync/"
log "running bootstrap.sh on $vm"
ssh -F "$SSH_CFG" "$SSH_HOST" 'sudo rsync -a --exclude core.env /tmp/core-sync/ /opt/core/ && rm -rf /tmp/core-sync && sudo bash /opt/core/bootstrap.sh'
