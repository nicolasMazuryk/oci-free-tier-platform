#!/usr/bin/env bash
# Manual FULL backup of core-bv-app-data. Refuses if it would exceed the
# 5 free volume backups. Prints the backup OCID (use with `make restore BACKUP=`).
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/bastion.sh"
suffix="${1:-$(date -u +%Y%m%d-%H%M)}"
comp="$(core_compartment)"
vol="$(oci bv volume list --compartment-id "$comp" --display-name core-bv-app-data --lifecycle-state AVAILABLE --query 'data[0].id' --raw-output)"
[[ -n $vol && $vol != null ]] || die "core-bv-app-data not found"
n_vol="$(oci bv backup list --compartment-id "$comp" --all --query 'length(data[?"lifecycle-state"!=`TERMINATED`])' --raw-output)"
n_boot="$(oci bv boot-volume-backup list --compartment-id "$comp" --all --query 'length(data[?"lifecycle-state"!=`TERMINATED`])' --raw-output)"
total=$(( n_vol + n_boot ))
log "existing backups: $n_vol volume + $n_boot boot = $total / 5 free"
(( total < 5 )) || die "5 backups already exist: delete an old manual one first (oci bv backup list --compartment-id $comp)"
log "creating FULL backup core-bkp-manual-$suffix (consistent at the block level; stop heavy writers first if you can)"
bid="$(oci bv backup create --volume-id "$vol" --type FULL --display-name "core-bkp-manual-$suffix" \
  --freeform-tags '{"scope":"core","managed-by":"backup-now"}' \
  --wait-for-state AVAILABLE --max-wait-seconds 3600 --query 'data.id' --raw-output)"
log "backup AVAILABLE"
echo "$bid"
