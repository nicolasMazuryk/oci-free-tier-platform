# oci-infra: core (OCI Always-Free)

This is one fixed, reusable infrastructure in Oracle Cloud `uk-london-1`, managed with Terraform. It runs:

- **an agent fleet:** 8–10 Claude Code Remote Control agents (`agent@<repo>`), driven from the Claude iPhone app or claude.ai/code. Each session gets its own git worktree.
- **web hosting:** Node/Next.js containers at `*.mazuryktech.com`, through Cloudflare (Full strict, Origin CA) to the NLB and on to Caddy.

Everything is Always-Free-eligible. The account is Pay-As-You-Go, so a $1 budget alert and `make free-tier` guard against charges.

```
Cloudflare (DNS/CDN/WAF, *.mazuryktech.com proxied)
   -> 203.0.113.10  core-nlb (reserved IP, Cloudflare-only NSG, preserve source)
       -> core-vm-app 10.0.2.10  (A1 2 OCPU/12 GB, /data 100 GB)
            Caddy (core-edge) -> project containers on docker network "edge"
            agent@<repo> x N  -> outbound HTTPS to Anthropic (no inbound ports)
       -> status.mazuryktech.com -> core-vm-ops 10.0.2.20:3001 (Uptime Kuma)
```

## Quickstart (operator laptop)

Prerequisites:
- Terraform 1.12 or later
- OCI CLI with a `DEFAULT` profile for the tenancy (home region uk-london-1)
- `jq`
- `gh`
- the SSH key `~/.ssh/oci_core` (`ssh-keygen -t rsa -b 4096 -f ~/.ssh/oci_core`)

```bash
make help
make init-foundation init-cloudflare init-core
make plan-all            # all three layers should say "no changes"
make ssh VM=app          # shell on the app VM via Bastion
make free-tier           # Always-Free compliance check
```

Starting from an empty tenancy: see [docs/runbooks/00-first-deploy.md](docs/runbooks/00-first-deploy.md).

## Day to day

| I want to... | Do |
|---|---|
| add a repo to the agent fleet | `make ssh VM=app`, then `fleet add <repo>` and `fleet attach <repo>` (accept trust). See [fleet-repos](docs/runbooks/fleet-repos.md) |
| deploy a web project | compose with Caddy labels on network `edge`. See [web-projects](docs/runbooks/web-projects.md) |
| store a secret | `make secret-put NAME=<slug>-secret-<purpose>` (hidden prompt) or `FILE=path` |
| change host config (Caddy, units, scripts) | edit `host/**`, then `make host-sync VM=app\|ops` |
| back up before something risky | `make backup` |
| rebuild everything except DNS/vault/state | `make wipe`, then `make restore BACKUP=<ocid>`. See [wipe-and-restore](docs/runbooks/wipe-and-restore.md) |

> **No TTY?** The `!` shell in Claude Code cannot show hidden prompts. Use
> `f=$(mktemp) && pbpaste > "$f" && make secret-put NAME=... FILE="$f"; rm -f "$f"`,
> and do `make ssh` / `claude auth login` / `fleet attach` from a real terminal.

## Docs

- [docs/architecture.md](docs/architecture.md): layers, network, security model, data flows
- `docs/runbooks/`:
  - [00-first-deploy](docs/runbooks/00-first-deploy.md)
  - [wipe-and-restore](docs/runbooks/wipe-and-restore.md)
  - [fleet-repos](docs/runbooks/fleet-repos.md)
  - [web-projects](docs/runbooks/web-projects.md)
  - [secrets-rotation](docs/runbooks/secrets-rotation.md)
  - [access-ssh](docs/runbooks/access-ssh.md)
  - [scaling-and-limits](docs/runbooks/scaling-and-limits.md)
  - [monitoring-alerts](docs/runbooks/monitoring-alerts.md)
  - [cloudflare](docs/runbooks/cloudflare.md)
  - [troubleshooting](docs/runbooks/troubleshooting.md)
- [CLAUDE.md](CLAUDE.md): the operating manual for Claude Code agents working in this repo (invariants, guardrails)
- [prompt.md](prompt.md): the original specification
