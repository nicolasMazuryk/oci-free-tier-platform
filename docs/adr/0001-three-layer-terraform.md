# 0001. Three Terraform layers with remote state and `prevent_destroy`

- Status: accepted
- Date: 2026-10-13

## Context

Some resources must outlive every rebuild: the state bucket, the Vault and its key, the reserved public IP that DNS points at, IAM and the budget. Others are cheap to recreate: network, load balancer, VMs. A single root module would put both in one state, so a wipe of the compute layer could destroy the vault, or `terraform destroy` could free the IP that DNS depends on.

## Decision

Split the infrastructure into three root modules, applied in order, each with its own state key in one Object Storage bucket (`core-bucket-tfstate`):

1. `foundation` (persistent): state bucket, Vault, key, reserved IP, IAM, alerts, budget, email.
2. `cloudflare` (persistent): DNS and TLS. It depends only on the reserved IP.
3. `core` (wipeable): VCN, NSGs, NLB, Bastion, VMs, data volume, alarms.

Layers read each other through `terraform_remote_state`. `prevent_destroy` is set on the bucket, vault, key and IP. The state bucket is versioned and old versions expire after 90 days. The foundation layer creates its own bucket, so it is bootstrapped once with local state and then migrated (`make bootstrap`).

## Consequences

- `make wipe` and `make restore` only touch the `core` layer, so DNS, secrets and state are never at risk.
- A change that spans layers needs two applies in order, and `make plan-all` must say "no changes" afterwards.
- The Object Storage namespace is account-specific and is passed to `terraform init` at run time rather than committed.
- Bootstrapping an empty tenancy has one special case (local state, then migration), which is documented in the first-deploy runbook.
