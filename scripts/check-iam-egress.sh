#!/usr/bin/env bash
# Assert the egress guard rails (offline, reads the Terraform source; add --live to also check the applied policy):
#   1. no instance-principal statement can read core-secret-egress-proxy-password or core-secret-cf-api-token
#   2. 0.0.0.0/0 INGRESS appears only on TCP 8443 (NSGs)
#   scripts/check-iam-egress.sh [--live]
# browser-use-api-key is deliberately readable by cloud (the cloud brain calls Browser Use).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS=(core-secret-egress-proxy-password core-secret-cf-api-token)
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
    # compartment "projects" holds no egress secret; only statements on core matter
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
files=("$root"/terraform/core/*.tf)
# a rule block: direction INGRESS + source 0.0.0.0/0 must have min = max = 8443
bad_rules="$(awk '
  /resource "oci_core_network_security_group_security_rule"/ { inres=1; dir=""; src=""; min=""; max="" }
  inres && /direction/ { dir=$3 }
  inres && /source[[:space:]]*=/ && !/source_type/ { src=$3 }
  inres && /min[[:space:]]*=/ { min=$3 }
  inres && /max[[:space:]]*=/ { max=$3 }
  inres && /^}/ {
    if (dir=="\"INGRESS\"" && src=="\"0.0.0.0/0\"") { n++; if (min!="8443" || max!="8443") print FILENAME": "$0 " (ports "min"-"max")" }
    inres=0
  }
  END { if (n=="") n=0; print "COUNT " n > "/dev/stderr" }
' "${files[@]}" 2>"${TMPDIR:-/tmp}/.nsgcount.$$")" || true
count="$(sed -n 's/^COUNT //p' "${TMPDIR:-/tmp}/.nsgcount.$$")"; rm -f "${TMPDIR:-/tmp}/.nsgcount.$$"
[[ -z $bad_rules ]] || bad "0.0.0.0/0 ingress on a port other than 8443: $bad_rules"
(( ${count:-0} >= 1 )) && ok "0.0.0.0/0 ingress rules: ${count}, all TCP 8443 only" || bad "expected the 8443 exception rules, found ${count:-0}"

exit $fail
