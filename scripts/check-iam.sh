#!/usr/bin/env bash
# Assert the guard rails (offline, reads the Terraform source; add --live to also check the applied policy):
#   1. no instance-principal statement can read core-secret-cf-api-token
#   2. no NSG rule allows 0.0.0.0/0 INGRESS
#   scripts/check-iam.sh [--live]
# browser-use-api-key is deliberately readable by cloud (the cloud brain calls Browser Use).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS=(core-secret-cf-api-token)
fail=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

# statements that let the dynamic group touch secrets (read/use/manage secret-family|secrets|secret-bundles)
check_statements() { # stdin: one policy statement per line
  local n=0 line
  while IFS= read -r line; do
    [[ $line =~ [Dd]ynamic-group ]] || continue
    [[ $line =~ (secret-family|secrets|secret-bundles|secret-versions|vaults) ]] || continue
    n=$((n+1))
    # compartment "projects" holds no guarded secret; only statements on core matter
    [[ $line =~ compartment[[:space:]]+.*projects ]] && continue
    for s in "${SECRETS[@]}"; do
      if [[ $line =~ target\.secret\.name[[:space:]]*!=[[:space:]]*\'$s\' ]]; then ok "excludes $s: ${line:0:90}..."
      else bad "can read $s: $line"; fi
    done
  done
  (( n > 0 )) || bad "no dynamic-group secret statement found (parser out of date?)"
}

echo "== IAM (terraform/foundation/iam.tf)"
check_statements < <(sed -n '/resource "oci_identity_policy" "compute"/,/^}/p' "$root/terraform/foundation/iam.tf" \
  | grep -o '"Allow [^"]*"' | tr -d '"')

if [[ ${1:-} == --live ]]; then
  echo "== IAM (applied policy core-pol-compute)"
  source "$root/scripts/lib.sh"
  check_statements < <(oci iam policy list --compartment-id "$TF_VAR_tenancy_ocid" --name core-pol-compute --all \
    | jq -r '.data[0].statements[]')
fi

echo "== NSG ingress from 0.0.0.0/0"
open_rules="$(awk '
  /resource "oci_core_network_security_group_security_rule"/ { inres=1; dir=""; src="" }
  inres && /direction/ { dir=$3 }
  inres && /source[[:space:]]*=/ && !/source_type/ { src=$3 }
  inres && /^}/ {
    if (dir=="\"INGRESS\"" && src=="\"0.0.0.0/0\"") print FILENAME": rule ending at line "FNR
    inres=0
  }
' "$root"/terraform/core/*.tf)"
[[ -z $open_rules ]] && ok "no 0.0.0.0/0 ingress rule" || bad "0.0.0.0/0 ingress: $open_rules"

exit $fail
