# 0007. Static egress IP: a reserved IP on the NAT gateway, with `cloud` as an exit node

- Status: accepted
- Date: 2026-10-24

## Context

SaaS consoles and crypto exchanges allowlist API keys and logins by source IPv4. That needs one egress address that never changes, for personal devices (Mac, iPhone) and for agents on `cloud`. The platform must stay Always-Free and keep its origin model: no public IP on a VM and no `0.0.0.0/0` ingress (ADR 0003, ADR 0004).

Constraints measured in this tenancy:

- Block and boot storage is full (200/200 GB). A new VM needs a boot volume of at least 47 GB, so there is no room for a third VM.
- A NAT gateway's public IP is ephemeral unless a reserved IP is assigned. `core-natgw` lives in the wipeable core layer.
- `cloud` has no public IP and no UDP ingress. Tailscale still forms a **direct** UDP path to it by NAT traversal: the peer's outbound packets open the mapping on `core-natgw` (the Mac, on a home network with a stable mapping, reaches `cloud` at `193.123.182.227:<port>`). It falls back to DERP only when the other side's network blocks UDP or uses hard (destination-dependent) NAT, e.g. some hotel, office or mobile-carrier networks.

## Decision

- **`core-pip-natgw`**, a `RESERVED` public IP in the foundation layer (`prevent_destroy`), is the `public_ip_id` of `core-natgw`. Both VMs leave the VCN from it, and it survives `make wipe`/`make restore`.
- **`macbook`, `iphone` and `cloud` are all tailnet exit nodes, and each device picks the exit node it uses, or none.** Bootstrap advertises `cloud` (`--advertise-exit-node`, IP forwarding on), and the tailnet policy in claude-code-fleet auto-approves `tag:cloud` and member devices. A device that uses an exit node does not offer one meanwhile (a Tailscale rule); picking none restores its offer.
- **The static IP means picking exit node `cloud`.** All of that device's traffic then leaves from `core-pip-natgw`. On the Mac this is `browser-router exit-node use cloud`; on the iPhone, the Tailscale app's Exit Node menu.
- **`cloud` only ever is an exit node and never uses one.** On Linux, using an exit node would route the replies to Cloudflare → NLB connections into the tailnet and break `*.mazuryktech.com`. It would also need a policy rule with `src: tag:cloud`, and the tailnet policy has none, so `cloud` never initiates a connection to the Mac or the iPhone.
- Per-domain routing (a Tailscale app connector) and per-app routing are not used: each adds a domain list or per-app setup to maintain, and a new allowlisted service would silently leave from the wrong address until someone updates it.
- A separate exit-node VM is not used because storage is full.
- No public IP or UDP ingress is added to improve the path, and a Tailscale peer relay is not used: both need a public IP with UDP ingress from anywhere, which ADR 0003 and ADR 0004 exclude. The direct path needs neither.

## Consequences

- A device reaches an allowlisted service from the static IP only while it uses exit node `cloud`; then all of its traffic takes that path, and the device offers no exit node itself.
- Allowlist entries are `core-pip-natgw` (`make output-foundation ARGS='-raw natgw_public_ip'`). They hold across wipe/restore.
- Exit-node performance on the direct path, measured 2026-10-25 from the Mac (home internet, Warsaw):

  | Path | Download | TCP connect to exchange APIs (Binance / Bybit / OKX) |
  |---|---|---|
  | `cloud` itself (NAT gateway) | ~1.6 Gbit/s | 6–19 ms |
  | Mac direct | ~355 Mbit/s | 37–41 ms |
  | Mac via exit node `cloud` | ~275 Mbit/s | ~100 ms (Bybit ~200 ms) |

  Mac ↔ `cloud` round trip is 43 ms. Bulk transfers lose about 20%; each new connection gains one Warsaw ↔ London round trip. Latency-sensitive workloads (trading) run on `cloud`, not through the exit node. On a DERP fallback, latency rises and throughput drops; `tailscale ping cloud` shows the path (`via <ip>:<port>` is direct, `via DERP(<region>)` is relayed).
- Through exit node `cloud`, IPv6 has no egress (the VCN is IPv4 only), so apps fall back to IPv4 and an allowlist never sees the device's own IPv6 address.
- Personal exit traffic passes through the agent host, where agents hold sudo. TLS protects content, but DNS, SNI and connection metadata are visible to root on `cloud`.
- An allowlist entry means "this tenancy", not "my laptop": agents on `cloud` and ops share the address. Exchange API keys stay off `cloud`, or are scoped per IP and per permission.
- `public_ip_id` is ForceNew on `oci_core_nat_gateway`, and the region allows one NAT gateway (`nat-gateway-count = 1`), so `create_before_destroy` is impossible. OCI also refuses to delete a NAT gateway that a route rule still targets. Replacing `core-natgw` therefore takes two steps: remove the `0.0.0.0/0` rule from `core-rt-priv` (OCI CLI), then `make apply-core`, which deletes the old gateway, creates the new one and restores the rule. Both VMs lose internet egress in between.
