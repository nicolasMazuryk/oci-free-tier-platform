#!/usr/bin/env bash
# Wipe the core layer (VMs, volume, network, NLB, Bastion, alarms, logs).
# foundation (vault, state, reserved IP, email, budget) and cloudflare stay.
# A manual FULL backup of /data is taken first; restore with `make restore BACKUP=<ocid>`.
source "$(dirname "$0")/lib.sh"
[[ -t 0 ]] || [[ "${CONFIRM:-}" == wipe ]] || die "needs a TTY or CONFIRM=wipe"
if [[ "${CONFIRM:-}" != wipe ]]; then
  read -rp "This destroys the whole core layer. Type 'wipe' to continue: " ok; [[ $ok == wipe ]] || exit 1
fi
if [[ "${SKIP_BACKUP:-}" != 1 ]]; then
  # Stop agents first so their state on /data is flushed (sessions resume after restore).
  "$(dirname "$0")/ssh.sh" cloud "sudo systemctl --no-pager stop 'agent@*'; sync" </dev/null \
    && log "stopped agent@* on cloud" || log "WARN: could not stop agents (VM down?): backing up anyway"
  bid="$("$(dirname "$0")/backup-now.sh" "prewipe-$(date -u +%Y%m%d-%H%M)")"
  echo "$bid" > "$REPO_ROOT/.last-wipe-backup"
  log "pre-wipe backup: $bid (also saved to .last-wipe-backup)"
fi
tf core destroy -input=false -auto-approve
log "core layer destroyed. Restore: make restore BACKUP=${bid:-<backup-ocid>}"
