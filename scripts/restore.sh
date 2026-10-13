#!/usr/bin/env bash
# Recreate the core layer. With a backup OCID, /data is restored from it
# (agent home, Claude login, gh auth, repos, Docker data come back).
#   scripts/restore.sh <volume-backup-ocid>   # restore /data
#   scripts/restore.sh none                   # fresh, empty /data
source "$(dirname "$0")/lib.sh"
b="${1:-}"
[[ -n $b ]] || { [[ -s "$REPO_ROOT/.last-wipe-backup" ]] && b="$(cat "$REPO_ROOT/.last-wipe-backup")"; }
[[ -n $b ]] || die "usage: make restore BACKUP=<volume-backup-ocid>|none"
args=()
if [[ $b != none ]]; then
  st="$(oci bv backup get --volume-backup-id "$b" --query 'data."lifecycle-state"' --raw-output)"
  [[ $st == AVAILABLE ]] || die "backup $b is $st"
  args+=(-var "data_volume_backup_id=$b")
  log "restoring core with /data from $b"
else
  log "restoring core with an EMPTY /data volume"
fi
tf core init -input=false >/dev/null
tf core apply -input=false -auto-approve ${args[@]+"${args[@]}"}
log "applied. cloud-init re-runs bootstrap.sh on first boot (~5-10 min). Check: make ssh VM=app CMD='sudo tail -n 30 /var/log/core-bootstrap.log'"
