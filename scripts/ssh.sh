#!/usr/bin/env bash
# SSH to a private VM through core-bastion (reuses a live session for up to 3 h).
#   scripts/ssh.sh cloud|ops [remote command...]
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/bastion.sh"
vm="${1:-cloud}"; shift || true
ssh_config "$vm"
tty=(); [[ -t 0 ]] && tty=(-t)
# Ubuntu has no terminfo for some modern terminals (Ghostty, kitty, wezterm...): fall back.
case "${TERM:-}" in xterm-ghostty|xterm-kitty|wezterm|alacritty|foot*) export TERM=xterm-256color ;; esac
exec ssh -F "$SSH_CFG" ${tty[@]+"${tty[@]}"} "$SSH_HOST" "$@"
