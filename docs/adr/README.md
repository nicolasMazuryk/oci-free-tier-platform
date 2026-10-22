# Architecture decision records

Format: [MADR](https://adr.github.io/madr/) (context, decision, consequences). Each record states one decision and the trade-off it accepts.

| ADR | Decision |
|---|---|
| [0001](0001-three-layer-terraform.md) | Three Terraform layers, remote state, `prevent_destroy` on what must survive |
| [0002](0002-always-free-only-with-budget-guard.md) | Always-Free resources only, with a budget guard and a compliance check |
| [0003](0003-cloudflare-only-ingress.md) | Cloudflare-only ingress, with IP-drift detection |
| [0004](0004-no-public-ips-bastion-tailscale.md) | No public IPs on VMs: Bastion for break-glass, Tailscale for daily access |
| [0005](0005-single-data-volume-and-vault.md) | One `/data` volume plus Vault make wipe and restore possible |
| [0006](0006-egress-proxy-public-8443.md) | Public TCP 8443 for the egress proxy: the single `0.0.0.0/0` ingress exception |
