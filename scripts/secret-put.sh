#!/usr/bin/env bash
# Create or update a Vault secret without the value ever touching argv, logs or git.
#   scripts/secret-put.sh <name> [file]
#   make secret-put NAME=core-secret-github-pat            # hidden prompt
#   make secret-put NAME=acme-secret-db-url FILE=./db.txt  # read from a file
# core-secret-* go to compartment "core"; anything else (<slug>-secret-*) to "projects".
# Every secret is encrypted with core-key-main in core-vault.
source "$(dirname "$0")/lib.sh"

name="${1:-}"; file="${2:-}"
[[ -n "$name" ]] || die "usage: $0 <secret-name> [file]"
[[ "$name" =~ ^[a-z0-9]+-secret-[a-z0-9-]+$ ]] || die "name must match <scope>-secret-<purpose> (got '$name')"

tenancy="$(oci_cfg tenancy)"
comp_name=projects; [[ "$name" == core-* ]] && comp_name=core
comp_id() { oci iam compartment list --compartment-id "$tenancy" --name "$1" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output; }
comp="$(comp_id "$comp_name")"; core="$(comp_id core)"
[[ -n "$comp" && "$comp" != null ]] || die "compartment $comp_name not found (apply foundation first)"

vault="$(oci kms management vault list --compartment-id "$core" --all \
  --query "data[?\"display-name\"=='core-vault' && \"lifecycle-state\"=='ACTIVE'].id | [0]" --raw-output)"
[[ -n "$vault" && "$vault" != null ]] || die "core-vault not found"
mgmt="$(oci kms management vault get --vault-id "$vault" --query 'data."management-endpoint"' --raw-output)"
key="$(oci kms management key list --compartment-id "$core" --endpoint "$mgmt" --all \
  --query "data[?\"display-name\"=='core-key-main' && \"lifecycle-state\"=='ENABLED'].id | [0]" --raw-output)"
[[ -n "$key" && "$key" != null ]] || die "core-key-main not found"

# ---- read the value (never echoed) ----
if [[ -n "$file" ]]; then
  [[ -r "$file" ]] || die "cannot read $file"
  value="$(cat "$file")"
else
  [[ -t 0 ]] || die "no TTY: pass a file path instead (scripts/secret-put.sh $name <file>)"
  read -rsp "Value for $name (hidden): " value; echo >&2
  read -rsp "Repeat to confirm: " value2; echo >&2
  [[ "$value" == "$value2" ]] || die "values do not match"
  unset value2
fi
[[ -n "$value" ]] || die "empty value"

tmp="$(mktemp -t secretput.XXXXXX)"; chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT
b64="$(printf '%s' "$value" | base64 | tr -d '\n')"; unset value

existing="$(oci vault secret list --compartment-id "$comp" --name "$name" --all \
  --query "data[?\"lifecycle-state\"!='DELETED'] | [0].{id:id,state:\"lifecycle-state\"}" 2>/dev/null || true)"
sid="$(jq -r '.id // empty' <<<"${existing:-null}")"; state="$(jq -r '.state // empty' <<<"${existing:-null}")"

if [[ -z "$sid" ]]; then
  jq -n --arg c "$comp" --arg v "$vault" --arg k "$key" --arg n "$name" --arg b "$b64" \
    '{compartmentId:$c, vaultId:$v, keyId:$k, secretName:$n, secretContentContent:$b,
      freeformTags:{"scope":(if ($n|startswith("core-")) then "core" else "project" end),"managed-by":"secret-put"}}' > "$tmp"
  unset b64
  sid="$(oci vault secret create-base64 --from-json "file://$tmp" --wait-for-state ACTIVE --query 'data.id' --raw-output)"
  log "created $name ($sid) in compartment $comp_name"
else
  case "$state" in
    PENDING_DELETION) die "$name is pending deletion; cancel it first: oci vault secret cancel-secret-deletion --secret-id $sid" ;;
    ACTIVE) ;;
    *) log "secret is $state, waiting for ACTIVE"; oci vault secret get --secret-id "$sid" --wait-for-state ACTIVE >/dev/null ;;
  esac
  jq -n --arg s "$sid" --arg b "$b64" '{secretId:$s, secretContentContent:$b}' > "$tmp"
  unset b64
  oci vault secret update-base64 --from-json "file://$tmp" --wait-for-state ACTIVE >/dev/null
  log "updated $name ($sid): new version is current"
fi
