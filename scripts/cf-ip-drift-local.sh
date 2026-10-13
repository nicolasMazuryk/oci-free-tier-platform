#!/usr/bin/env bash
# Laptop version of the weekly ops cron: compare Cloudflare IPv4 ranges with core-nsg-app.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/bastion.sh"
want="$(curl -fsS https://www.cloudflare.com/ips-v4 | grep -E '^[0-9]' | sort -u)"
nsg="$(oci network nsg list --compartment-id "$(core_compartment)" --display-name core-nsg-app --query 'data[0].id' --raw-output)"
have="$(oci network nsg rules list --nsg-id "$nsg" --all --direction INGRESS --query 'data[?description==`cloudflare`].source' | jq -r '.[]' | sort -u)"
if [[ $want == "$have" ]]; then log "no drift ($(wc -l <<<"$want" | tr -d ' ') ranges)"; else diff <(echo "$have") <(echo "$want"); die "drift: run make apply-core"; fi
