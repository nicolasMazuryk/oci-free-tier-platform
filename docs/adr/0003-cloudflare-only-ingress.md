# 0003. Cloudflare-only ingress with IP-drift detection

- Status: accepted
- Date: 2026-10-13

## Context

Web projects are served from a single reserved IP. If the origin accepts traffic from anywhere, scanners and DDoS traffic reach Caddy directly and bypass the Cloudflare WAF. Cloudflare publishes its IPv4 ranges, and they change occasionally.

## Decision

- DNS records (`@` and `*`) are proxied through Cloudflare, with SSL mode Full (strict) and a 15-year Cloudflare Origin CA certificate stored in Vault.
- The NLB and cloud network security groups allow TCP 443 only from the Cloudflare IPv4 ranges. Terraform fetches the ranges from `cloudflare.com/ips-v4` at plan time and creates one rule per range. All ingress is expressed in NSGs; the shared security list only allows egress.
- The NLB preserves the client source IP, so the NSG sees the real caller. Applications read the visitor from `CF-Connecting-IP`.
- A weekly cron on the ops VM (`core-cf-ip-drift`) compares the published ranges with the NSG and sends an alert on topic `core-topic-alerts` when they differ. `make drift` runs the same check locally.

## Consequences

- Hitting the origin IP directly times out, which is easy to test (`curl -m 8 -k https://<ip>`).
- Cloudflare range changes need a `terraform apply` of the `core` layer. The drift alert is the trigger, so the gap is at most a week.
- All traffic depends on Cloudflare, and sites must stay one subdomain level deep because the free certificate covers `*.example.com` only.
