# 0006. Browser Use egresses through a Polish ISP proxy; no self-hosted gateway ingress

- Status: accepted
- Date: 2026-10-22

## Context

Browser Use cloud browsers need an exit with a Polish residential address. They connect from addresses Browser Use does not publish, so a gateway hosted on `cloud` would have to accept connections from anywhere on its own port, which ADR 0003 forbids.

## Decision

- Browser Use goes direct through a Polish ISP proxy. This platform hosts no egress gateway: `core-nlb` has only the 443 listener, and `core-nsg-nlb` and `core-nsg-cloud` accept TCP 443 from the Cloudflare IPv4 ranges and nothing from `0.0.0.0/0`.
- There is no `egress.mazuryktech.com` record. The proxied wildcard is the only application record.
- `core-pol-compute` reads every secret in `core` except `core-secret-cf-api-token`, which only the Mac's `terraform/cloudflare` uses and which carries zone-wide DNS/SSL edit.
- `core-secret-browser-use-api-key` stays readable by `cloud`: the cloud brain calls Browser Use (shield login, `browser-use` executor).
- `make check-iam` asserts the token exclusion and that no NSG rule allows `0.0.0.0/0` ingress (`LIVE=1` also checks the applied policy).

## Consequences

- The origin stays reachable only from Cloudflare, as ADR 0003 states, with no exceptions.
- Proxy credentials and the ISP relationship belong to the Browser Use configuration, not to this repo.
- A self-hosted gateway is not used because it needs internet-wide ingress on a non-Cloudflare port, which this platform's origin model excludes.
