#!/usr/bin/env bash
# Weekly: diff https://www.cloudflare.com/ips-v4 against the Cloudflare
# ingress rules of core-nsg-app; alert core-topic-alerts on any drift.
# Fix: `make plan-core` / `make apply-core` (the NSG is built from the live list).
source /opt/core/lib.sh
want="$(curl -fsS https://www.cloudflare.com/ips-v4 | grep -E '^[0-9]' | sort -u)"
[[ -n "$want" ]] || { log "could not fetch Cloudflare ranges"; exit 1; }
nsg="$(oci network nsg list --compartment-id "$COMPARTMENT_ID" --display-name core-nsg-app --query 'data[0].id' --raw-output)"
have="$(oci network nsg rules list --nsg-id "$nsg" --all --direction INGRESS \
  --query 'data[?description==`cloudflare`].source' | jq -r '.[]' | sort -u)"
if [[ "$want" == "$have" ]]; then
  log "no drift ($(wc -l <<<"$want") ranges)"
else
  d="$(diff <(echo "$have") <(echo "$want") || true)"
  log "DRIFT:"; echo "$d"
  notify "core: Cloudflare IP ranges drifted from core-nsg-app" \
    "Cloudflare ips-v4 no longer matches core-nsg-app (< in NSG only, > at Cloudflare only):
$d

Fix: from the repo run 'make plan-core' then 'make apply-core'."
fi
