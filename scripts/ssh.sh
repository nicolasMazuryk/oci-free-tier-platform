#!/usr/bin/env bash
# SSH to a private VM through core-bastion (reuses a live session for 3 h).
#   scripts/ssh.sh app|ops [remote command...]
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/bastion.sh"
vm="${1:-app}"; shift || true
ssh_opts "$vm"
tty=(); [[ -t 0 ]] && tty=(-t)
exec ssh "${SSH_OPTS[@]}" ${tty[@]+"${tty[@]}"} -o LogLevel=ERROR "$TARGET" "$@"
