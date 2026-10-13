#!/usr/bin/env bash
# Inventory the tenancy and flag anything that is not Always Free.
# Exit 1 if any check fails. Limits: A1 <=4 OCPU/24 GB, <=2 E2.1.Micro,
# block+boot <=200 GB, <=5 volume backups, <=1 NLB, flexible LB <=1 at 10 Mbps,
# DEFAULT vault + SOFTWARE keys only, APM free tier.
source "$(dirname "$0")/lib.sh"
tenancy="$TF_VAR_tenancy_ocid"; fail=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
comps="$(oci iam compartment list --compartment-id "$tenancy" --compartment-id-in-subtree true --all \
  --lifecycle-state ACTIVE --query 'data[].id' | jq -r '.[]'; echo "$tenancy")"
each() { for c in $comps; do "$@" --compartment-id "$c" --all 2>/dev/null | jq -c '(.data | if type=="object" then (.items // []) else (. // []) end)[]' ; done; }

echo "== compute"
inst="$(each oci compute instance list | jq -s '[.[]|select(."lifecycle-state"!="TERMINATED")]')"
jq -r '.[]|"  \(."display-name")\t\(.shape)\t\(."shape-config".ocpus) OCPU\t\(."shape-config"."memory-in-gbs") GB\t\(."lifecycle-state")"' <<<"$inst"
a1o="$(jq '[.[]|select(.shape=="VM.Standard.A1.Flex")|."shape-config".ocpus]|add//0' <<<"$inst")"
a1m="$(jq '[.[]|select(.shape=="VM.Standard.A1.Flex")|."shape-config"."memory-in-gbs"]|add//0' <<<"$inst")"
micro="$(jq '[.[]|select(.shape=="VM.Standard.E2.1.Micro")]|length' <<<"$inst")"
other="$(jq -r '[.[]|select(.shape!="VM.Standard.A1.Flex" and .shape!="VM.Standard.E2.1.Micro")|."display-name"]|join(",")' <<<"$inst")"
awk "BEGIN{exit !($a1o<=4 && $a1m<=24)}" && ok "A1: $a1o OCPU / $a1m GB (<=4/24)" || bad "A1: $a1o OCPU / $a1m GB exceeds 4/24"
(( micro <= 2 )) && ok "E2.1.Micro: $micro (<=2)" || bad "E2.1.Micro: $micro > 2"
[[ -z $other ]] && ok "no other shapes" || bad "non-free shapes: $other"

echo "== storage"
ads="$(oci iam availability-domain list --compartment-id "$tenancy" --query 'data[].name' | jq -r '.[]')"
bv=0; boot=0
for c in $comps; do
  v="$(oci bv volume list --compartment-id "$c" --all 2>/dev/null | jq '[.data[]?|select(."lifecycle-state"!="TERMINATED")|."size-in-gbs"]|add//0')"; bv=$((bv+v))
  for ad in $ads; do
    b="$(oci bv boot-volume list --compartment-id "$c" --availability-domain "$ad" --all 2>/dev/null | jq '[.data[]?|select(."lifecycle-state"!="TERMINATED")|."size-in-gbs"]|add//0')"; boot=$((boot+b))
  done
done
(( bv + boot <= 200 )) && ok "block $bv GB + boot $boot GB = $((bv+boot)) GB (<=200)" || bad "volumes $((bv+boot)) GB > 200"
nb="$(each oci bv backup list | jq -s '[.[]|select(."lifecycle-state"!="TERMINATED")]|length')"
nbb="$(each oci bv boot-volume-backup list | jq -s '[.[]|select(."lifecycle-state"!="TERMINATED")]|length')"
(( nb + nbb <= 5 )) && ok "backups: $nb volume + $nbb boot (<=5)" || bad "backups: $((nb+nbb)) > 5 (billed)"
vpu="$(each oci bv volume list | jq -s '[.[]|select(."lifecycle-state"!="TERMINATED" and ."vpus-per-gb">10)]|length')"
(( vpu == 0 )) && ok "all volumes at Balanced (10 VPU)" || bad "$vpu volumes above 10 VPU/GB (billed)"

echo "== networking"
nlb="$(each oci nlb network-load-balancer list | jq -s '[.[]|select(."lifecycle-state"!="DELETED")]|length')"
(( nlb <= 1 )) && ok "NLB: $nlb (<=1)" || bad "NLB: $nlb > 1"
lbs="$(each oci lb load-balancer list | jq -s '[.[]|select(."lifecycle-state"!="DELETED")]')"
nlbs="$(jq length <<<"$lbs")"; bigl="$(jq '[.[]|select(."shape-name"!="flexible" or ."shape-details"."maximum-bandwidth-in-mbps">10)]|length' <<<"$lbs")"
(( nlbs <= 1 && bigl == 0 )) && ok "flexible LB: $nlbs (<=1 @10 Mbps)" || bad "load balancers: $nlbs (non-free: $bigl)"

echo "== security / observability"
vaults="$(each oci kms management vault list | jq -s '[.[]|select(."lifecycle-state"=="ACTIVE")]')"
vp="$(jq '[.[]|select(."vault-type"!="DEFAULT")]|length' <<<"$vaults")"
(( vp == 0 )) && ok "vaults: $(jq length <<<"$vaults") DEFAULT" || bad "$vp non-DEFAULT (virtual private) vault(s): billed"
for ep in $(jq -r '.[]."management-endpoint"' <<<"$vaults"); do
  for c in $comps; do
    hk="$(oci kms management key list --compartment-id "$c" --endpoint "$ep" --all 2>/dev/null | jq '[.data[]?|select(."lifecycle-state"=="ENABLED" and ."protection-mode"!="SOFTWARE")]|length')"
    (( ${hk:-0} == 0 )) || bad "$hk HSM/EXTERNAL key(s) (20 HSM key versions free; check usage)"
  done
done
ok "vault keys checked (SOFTWARE)"
apm="$(each oci apm-control-plane apm-domain list | jq -s '[.[]|select(."lifecycle-state"=="ACTIVE")]')"
napm="$(jq '[.[]|select(."is-free-tier"!=true)]|length' <<<"$apm")"
(( napm == 0 )) && ok "APM domains: $(jq length <<<"$apm") free tier" || bad "$napm paid APM domain(s)"

echo "== everything (resource search)"
oci search resource structured-search --query-text "query all resources where lifecycleState != 'TERMINATED' && lifecycleState != 'DELETED'" --limit 1000 \
  | jq -r '.data.items[]|.["resource-type"]' | sort | uniq -c | sort -rn | sed 's/^/  /'
echo; (( fail == 0 )) && echo "free-tier check: PASS" || { echo "free-tier check: FAIL"; exit 1; }
