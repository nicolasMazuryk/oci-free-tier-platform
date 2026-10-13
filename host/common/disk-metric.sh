#!/usr/bin/env bash
# OCI has no built-in filesystem-usage metric: post one per mount to
# namespace core_custom, metric disk_used_pct (instance principal).
source /opt/core/lib.sh
iid="$(curl -s -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/id)"
host="$(hostname)"
ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
items=()
for m in ${DISK_METRIC_MOUNTS:-/}; do
  mountpoint -q "$m" || continue
  pct="$(df --output=pcent "$m" | tail -1 | tr -dc '0-9')"
  items+=("$(jq -n --arg c "$COMPARTMENT_ID" --arg i "$iid" --arg h "$host" --arg m "$m" --arg t "$ts" --argjson v "$pct" \
    '{namespace:"core_custom", compartmentId:$c, name:"disk_used_pct",
      dimensions:{resourceId:$i, host:$h, mount:$m}, datapoints:[{timestamp:$t, value:$v}]}')")
done
[[ ${#items[@]} -gt 0 ]] || exit 0
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
printf '%s\n' "${items[@]}" | jq -s . > "$tmp"
oci monitoring metric-data post --endpoint "https://telemetry-ingestion.${REGION}.oraclecloud.com" \
  --metric-data "file://$tmp" >/dev/null
