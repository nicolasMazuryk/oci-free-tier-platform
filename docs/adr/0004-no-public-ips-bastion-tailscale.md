# 0004. No public IPs on VMs: Bastion for break-glass, Tailscale for daily access

- Status: accepted
- Date: 2026-10-14

## Context

The VMs need operator access (shells, deploys, `rsync`) and the agent VM needs to be reachable from a phone and a laptop. Public IPs and open SSH ports would expose both VMs to the internet and add NSG rules to maintain. The VMs only need outbound access (Anthropic API, GitHub, package mirrors).

## Decision

- Both VMs live in a private subnet with no public IP. Outbound traffic goes through a NAT gateway, and Oracle services through a service gateway.
- **Break-glass access** is the OCI Bastion service. `make ssh` creates a port-forwarding session (reused for up to 3 h) and tunnels SSH through it. The NSGs allow port 22 only from the Bastion endpoint /32.
- **Daily access** is Tailscale: the app VM joins the tailnet as node `cloud` (`tag:cloud`) with Tailscale SSH and mosh. Both ends connect outbound, so no NSG rule, public IP or open port is involved. The tailnet policy has no rule with `src: tag:cloud`, so the VM cannot open connections back to personal devices. This follows the same model as the `claude-code-fleet` project (its ADR 0001).
- Node state is kept on `/data/core/tailscale`, so it survives a wipe and restore.

## Consequences

- There is no inbound path to the VMs apart from Cloudflare to the NLB on port 443 (ADR 0003).
- Bastion sessions need the SSH key and take a few seconds to create. The Bastion client CIDR defaults to `0.0.0.0/0` and can be narrowed with `bastion_client_cidrs`.
- Tailscale is a hard dependency for the convenient path. If it is down, Bastion is the fallback.
