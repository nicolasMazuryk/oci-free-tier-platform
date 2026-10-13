#!/usr/bin/env bash
# First-ever foundation deploy: apply with local state, then migrate the state
# into core-bucket-tfstate (which this layer creates). Idempotent: if the
# bucket already exists, it just runs `terraform init` against it.
source "$(dirname "$0")/lib.sh"
dir="$REPO_ROOT/terraform/foundation"
ns="$(oci os ns get --query data --raw-output)"

if oci os bucket get --namespace-name "$ns" --bucket-name core-bucket-tfstate >/dev/null 2>&1; then
  log "core-bucket-tfstate exists: initialising remote backend"
  tf foundation init -input=false
  exit 0
fi

log "No state bucket yet: applying foundation with a temporary local backend"
cat > "$dir/backend_override.tf" <<'HCL'
terraform {
  backend "local" {}
}
HCL
trap 'rm -f "$dir/backend_override.tf"' EXIT
tf foundation init -input=false -reconfigure
tf foundation apply -input=false "$@"

log "Migrating local state into core-bucket-tfstate"
rm -f "$dir/backend_override.tf"
tf foundation init -input=false -migrate-state -force-copy
rm -f "$dir/terraform.tfstate" "$dir/terraform.tfstate.backup"
log "Done. State now in oci://core-bucket-tfstate/foundation/terraform.tfstate"
