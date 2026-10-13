# Scaling and Always-Free limits

This tenancy is **Pay-As-You-Go**. Anything beyond Always-Free is billed immediately.
- `make free-tier` checks the current state and exits 1 if anything is out of bounds.
- `core-budget-monthly` ($1) emails at 50% and 100% of actual spend, and when the forecast passes 100%.

## Budget vs. use

| Resource | Always-Free | Used | Headroom |
|---|---|---|---|
| A1 Flex | 4 OCPU / 24 GB (3000 OCPU-h + 18000 GB-h per month) | app 2 / 12 | 2 OCPU / 12 GB |
| E2.1.Micro | 2 instances (AD-1 only in London) | ops | 1 |
| Boot + block volume | 200 GB total | 50 + 50 + 100 = **200** | **0**. Growing anything means shrinking something else. |
| Volume performance | Balanced (10 VPU/GB) | 10 | n/a (higher VPU is billed) |
| Volume backups | 5 (boot + block) | policy keeps 3 | 2 for manual backups |
| NLB / flexible LB | 1 / 1 (10 Mbps) | 1 / 0 | 1 LB |
| Reserved public IPs | free | 1 (+ the NAT gateway's IP) | n/a |
| Vault | DEFAULT vault, SOFTWARE keys, 150 secrets | 1 / 1 key / ~9 secrets | many |
| Object Storage | 20 GB | tfstate (KB) | n/a |
| Logging | 10 GB/month | small | n/a |
| Monitoring | 500M ingestion datapoints, 50 alarms | 5 alarms | n/a |
| Notifications | 1000 email/month | low | n/a |
| Email Delivery | 100/day (approx. 3000/month) | low | n/a |
| APM | free-tier domain: 1000 tracing events/hour | core-apm | n/a |
| Bastion | free | 1 | n/a |

## Scaling the app VM (within free)

Set these in `terraform/core/terraform.tfvars` (gitignored):

```hcl
app_ocpus     = 4
app_memory_gb = 24
```

- Changing the shape config of an A1 Flex instance makes OCI **reboot** it. `apply-core` shows it as an in-place update.
- Running agents come back through systemd.
- Take a `make backup` first if you're nervous.

## Growing /data

There is no free headroom. To grow `/data` by X GB, shrink something else by X:
- `boot_volume_gb` applies only to new VMs, and can't be smaller than 47 GB.
- Alternatively, move ops to a smaller boot volume on a rebuild.

Resizing a volume online:
1. Bump `data_volume_gb` and apply.
2. Bootstrap's `resize2fs` grows the filesystem on the next `make host-sync VM=app`.
3. You may need to rescan first: `sudo bash -c 'echo 1 > /sys/class/block/sdb/device/rescan'`.

## Things that are NOT free (do not create without the human)

- Any shape other than A1.Flex or E2.1.Micro (including E4/E5 Flex).
- Volumes above 10 VPU/GB.
- More than 5 backups.
- A second NLB.
- A flexible LB above 10 Mbps.
- A Virtual Private Vault.
- HSM keys beyond the free 20 versions.
- Paid APM domains.
- Resource Manager private endpoints.
- More than 200 GB of block storage.
- Outbound data above 10 TB/month.

## Capacity errors

`Out of host capacity` for A1 in AD-1:
- Retry later, or set `app_ad_index = 1` or `2`.
- The data volume must be in the same AD as the instance. Terraform creates it in the instance's AD, and a volume backup can be restored into any AD, so `make restore BACKUP=...` with a new `app_ad_index` works.
