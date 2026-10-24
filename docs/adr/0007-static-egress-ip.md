# 0007. Static egress IP: a reserved IP on the NAT gateway, with `cloud` as the tailnet exit node

- Status: accepted
- Date: 2026-10-24

## Context

SaaS consoles and crypto exchanges allowlist API keys and logins by source IPv4. That needs one egress address that never changes, for personal devices (Mac, iPhone) and for agents on `cloud`. The platform must stay Always-Free and keep its origin model: no public IP on a VM and no `0.0.0.0/0` ingress (ADR 0003, ADR 0004).

Constraints measured in this tenancy:

- Block and boot storage is full (200/200 GB). A new VM needs a boot volume of at least 47 GB, so there is no room for a third VM.
- A NAT gateway's public IP is ephemeral unless a reserved IP is assigned. `core-natgw` lives in the wipeable core layer.
- The OCI NAT gateway and typical home networks are hard NAT. A tailnet peer behind `core-natgw` therefore talks through DERP, not over a direct UDP path.

## Decision

- **`core-pip-natgw`**, a `RESERVED` public IP in the foundation layer (`prevent_destroy`), is the `public_ip_id` of `core-natgw`. Both VMs leave the VCN from it, and it survives `make wipe`/`make restore`.
- **`cloud` is the tailnet exit node** for personal devices and for browser-router. Bootstrap already advertises it (`--advertise-exit-node`, IP forwarding on), and the tailnet policy in claude-code-fleet auto-approves `tag:cloud`.
- **`cloud` is also the tailnet app connector** (`--advertise-connector`). The domains listed under `tailscale.com/app-connectors` in claude-code-fleet's `policy.hujson` (the exchanges, plus the probe `checkip.amazonaws.com`) leave through `cloud` from `core-pip-natgw`. This holds for every device that accepts routes, even while it uses no exit node or is an exit node itself. The Mac uses this path and keeps advertising itself as an exit node; a device that wants all of its traffic on the static IP picks `cloud` as its exit node instead.
- A separate exit-node VM is not used because storage is full.
- A direct (non-DERP) path or a Tailscale peer relay is not used because both need a public IP with UDP ingress from anywhere, which ADR 0003 and ADR 0004 exclude.

## Consequences

- A new allowlisted service needs its domains added to the app-connector list; otherwise the Mac reaches it from its own address.
- Allowlist entries are `core-pip-natgw` (`make output-foundation ARGS='-raw natgw_public_ip'`). They hold across wipe/restore.
- Exit-node throughput is bounded by DERP: fine for API and console use, not for bulk downloads. Latency is close to a direct path (DERP `lhr` is a few ms from `cloud`).
- Personal exit traffic passes through the agent host, where agents hold sudo. TLS protects content, but DNS, SNI and connection metadata are visible to root on `cloud`.
- An allowlist entry means "this tenancy", not "my laptop": agents on `cloud` and ops share the address. Exchange API keys stay off `cloud`, or are scoped per IP and per permission.
- `public_ip_id` is ForceNew on `oci_core_nat_gateway`, and the region allows one NAT gateway (`nat-gateway-count = 1`), so `create_before_destroy` is impossible. OCI also refuses to delete a NAT gateway that a route rule still targets. Replacing `core-natgw` therefore takes two steps: remove the `0.0.0.0/0` rule from `core-rt-priv` (OCI CLI), then `make apply-core`, which deletes the old gateway, creates the new one and restores the rule. Both VMs lose internet egress in between.
