# 0006. Public TCP 8443 for the egress proxy, the single `0.0.0.0/0` exception

- Status: accepted
- Date: 2026-10-22

## Context

Browser Use cloud browsers reach the internet through a custom proxy that we supply. They connect from addresses Browser Use does not publish, so an allow-list NSG rule is impossible. The proxy (gost on `cloud`, owned by claude-code-fleet) must therefore be reachable from anywhere on one port. ADR 0003 forbids `0.0.0.0/0` ingress.

## Decision

- `core-nlb` gets TCP listener `core-lsn-egress` on 8443 -> backend set `core-bes-egress` -> `core-vm-cloud:8443` (TCP health check, preserve source).
- `core-nsg-nlb` and `core-nsg-cloud` accept `0.0.0.0/0` on TCP 8443 and nothing else. Port 443 stays Cloudflare-only.
- The listener serves TLS with gost basic auth (a long random password, `core-secret-egress-proxy-password` in Vault). Abuse limits are enforced by fleet: gost bypass and limiter, nftables in the egress namespace keyed on gost's uid, and a daily-bytes alert (claude-code-fleet ADR 0007).
- The password reaches `cloud` through `claude-code-fleet` install from the Mac, never through the instance principal. `core-pol-compute` reads every secret in `core` except `core-secret-egress-proxy-password` and `core-secret-cf-api-token` (`where all {target.secret.name != ..., ...}`), so a compromised VM process cannot read either. The Cloudflare token is used only by the Mac's `terraform/cloudflare` and carries zone-wide DNS/SSL edit.
- The gateway is `egress.mazuryktech.com`, an `A` record to the reserved IP, **DNS only** (`proxied = false`). The explicit record overrides the proxied wildcard; Cloudflare cannot proxy a forward proxy on 8443, and Cloudflare-proxied traffic would not reach the NLB listener as TCP 8443 anyway. The gateway serves a publicly trusted certificate for this name (claude-code-fleet ADR 0007), so clients verify it.
- `core-secret-browser-use-api-key` stays readable by `cloud`: the cloud brain calls Browser Use (shield login, `browser-use` executor).
- `make check-iam` asserts both IAM exclusions and that every `0.0.0.0/0` ingress rule is TCP 8443 only (`LIVE=1` also checks the applied policy).

## Consequences

- The origin is no longer reachable only from Cloudflare: 8443 is internet-facing and is protected by TLS, basic auth and fleet's egress limits.
- A leaked proxy password lets anyone use the egress path within those limits until the secret is rotated (`secrets-rotation.md`).
- Further hardening (per-source allow-lists, mTLS) is not part of this design.
