#!/usr/bin/env bash
# SSH to a private VM through core-bastion (reuses a live session for up to 3 h).
#   scripts/ssh.sh app|ops [remote command...]
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/bastion.sh"
vm="${1:-app}"; shift || true
ssh_config "$vm"
tty=(); [[ -t 0 ]] && tty=(-t)
exec ssh -F "$SSH_CFG" ${tty[@]+"${tty[@]}"} "$SSH_HOST" "$@"
