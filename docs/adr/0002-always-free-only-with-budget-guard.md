# 0002. Always-Free resources only, with a budget guard

- Status: accepted
- Date: 2026-10-13

## Context

The platform is meant to run at no cost. The tenancy is Pay-As-You-Go, which bills anything outside the Always-Free limits. One wrong shape or volume size would produce a charge without any warning.

## Decision

- Only Always-Free-eligible resources are used: A1 compute (at most 4 OCPU / 24 GB in total across the tenancy), one `E2.1.Micro`, at most 200 GB of block plus boot volume, one flexible NLB, one Bastion, a shared Vault, and free-tier Email Delivery, APM and logging quotas.
- A monthly budget of $1 on the whole tenancy alerts at 50% and 100% of actual spend and at 100% of forecast.
- `make free-tier` (`scripts/check-free-tier.sh`) inventories the tenancy and exits non-zero on a violation. The compute and volume sizes are Terraform variables with the limits written next to them.

## Consequences

- A mistake is caught by the check before it is applied, or by the budget alert, instead of on the invoice.
- Capacity is tight. If A1 capacity is exhausted in AD-1, `cloud_ad_index` moves the cloud VM to another AD, but the micro VM must stay in AD-1.
- Features that are not free (a larger volume, extra A1 capacity, a virtual private vault) are out of scope by design.
