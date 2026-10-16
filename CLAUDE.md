# CLAUDE.md: operating manual for this repo

This repo is the Terraform and host provisioning for **core**, one reusable OCI Always-Free
infrastructure in `uk-london-1`. It serves two purposes:

1. The **machine for an agent fleet** on `core-vm-cloud`. **Everything Claude Code is owned by
   [claude-code-fleet](https://github.com/nicolasMazuryk/claude-code-fleet)** (`~/Documents/claude-code-fleet`, its ADR 0002):
   the Claude Code binary, settings, hooks, Agent View (`cc-agents.service`), the Remote Control units
   (`cc-rc@<repo>.service`), repos in `/data/fleet` and `fleet` (a Mac CLI). This repo keeps the VM, disk, packages,
   the `agent` user (+ linger, sudo, gh auth), Tailscale (node `cloud`, `tag:cloud`), the mosh firewall rule, Vault
   secrets and log shipping. **Never add Claude Code install/config/units here**; the bootstrap only removes the legacy
   `agent@`/`fleet` setup older versions installed and never touches `cc-*` units.
   Rebuild path: `make restore`/`make host-sync VM=cloud` here → `./install.sh cloud` in cc-orchestrator (from the Mac).
2. **Web hosting**: `*.mazuryktech.com` through Cloudflare, served by Caddy on `core-vm-cloud`.

The original spec is `prompt.md`. Human docs are in `README.md`, `docs/architecture.md` and `docs/runbooks/`.

The account is **Pay-As-You-Go**. Anything that is not Always-Free is billed, so read
"Free-tier limits" below before you create anything.

## Layer map (three Terraform states, one bucket)

| Layer | Dir | State key | Lifecycle | Holds |
|---|---|---|---|---|
| foundation | `terraform/foundation` | `foundation/terraform.tfstate` | **Persistent**. Never destroy. | compartments `core` and `projects`, `core-bucket-tfstate`, `core-vault` + `core-key-main`, reserved IP `core-pip-nlb`, `core-dg-compute` / `core-pol-compute` / `core-pol-objectstorage`, `core-topic-alerts` + email sub, `core-budget-monthly`, Email Delivery (domain, `core-dkim`, `noreply@`, SMTP cred, which goes to `core-secret-smtp`), `core-apm` (keys go to `core-secret-apm-*-key`), `core-secret-uptime-kuma-admin` |
| cloudflare | `terraform/cloudflare` | `cloudflare/terraform.tfstate` | Persistent, idempotent | DNS (apex + `*` A records to the reserved IP, proxied; SPF/DKIM/DMARC DNS-only), zone TLS settings, Origin CA cert (written to `core-secret-cf-origin-cert` and `-key`) |
| core | `terraform/core` | `core/terraform.tfstate` | **Wipeable** (`make wipe` / `make restore`) | VCN/subnets/gateways/route tables, NSGs, `core-nlb`, `core-bastion`, both VMs, `core-bv-cloud-data`, `core-bkp-daily-3d`, logs, alarms |

- Order of dependence: foundation, then cloudflare, then core. Downstream layers read
  `terraform_remote_state` from the oci backend.
- DNS points at the **persistent reserved IP**, so wiping core never touches Cloudflare.
- The bucket is `core-bucket-tfstate`, in your tenancy Object Storage namespace (`oci os ns get`). It is versioned, and old versions expire after 90 days.
- The Cloudflare provider token is read from Vault (`core-secret-cf-api-token`). It is never in a file.

## Commands (always run from the repo root)

```bash
make help                       # every target
make init-<layer>               # foundation | cloudflare | core
make plan-<layer> / apply-<layer> [ARGS='-target=...']
make plan-all                   # expect "no changes" x3 after any apply
make output-<layer> ARGS='-raw nlb_public_ip'
make ssh VM=cloud|ops [CMD='...'] # through core-bastion (session reused for up to 3 h)
make host-sync VM=cloud|ops       # rsync host/common + host/<vm> to /opt/core, re-run bootstrap.sh
make secret-put NAME=<scope>-secret-<purpose> [FILE=path]
make backup [NAME=suffix]       # manual FULL backup of core-bv-cloud-data (refuses past 5 backups)
make wipe                       # backup, then destroy core layer   (ASK THE HUMAN FIRST)
make restore BACKUP=<ocid>|none # recreate core; /data from backup
make free-tier                  # inventory + Always-Free check (exit 1 on violation)
make drift                      # Cloudflare IPv4 ranges vs core-nsg-cloud
make bootstrap                  # first-ever foundation deploy (local state, then migrate)
```

- The Makefile and `scripts/lib.sh` export `TF_VAR_tenancy_ocid` and `TF_VAR_user_ocid` from `~/.oci/config`
  (profile `DEFAULT`, or `OCI_PROFILE=`). A `terraform.tfvars` is only needed for the Cloudflare layer (`zone_id`, required) and to override defaults.
  Optional overrides are listed in `terraform.tfvars.example`.
- macOS ships bash 3.2, so scripts avoid `${arr[@]}` on empty arrays under `set -u`. Use `${arr[@]+"${arr[@]}"}`.
- The `!` shell inside Claude Code has **no TTY**. Interactive steps fail there: the `secret-put` hidden prompt,
  `make ssh` without CMD and `claude auth login`. To put a secret from it, use the file form:
  `f=$(mktemp) && pbpaste > "$f" && make secret-put NAME=... FILE="$f"; rm -f "$f"`.

## Invariants: do not break these

1. **Never** `terraform destroy` foundation or cloudflare. Never destroy core without the human's explicit OK.
   `prevent_destroy` is set on the bucket, vault, key and reserved IP.
2. **Secrets live only in Vault**, plus the private state bucket.
   - Never put a secret value on argv, in chat, in logs or in git.
   - Use `scripts/secret-put.sh`, which reads a hidden prompt or a file and sends the value via a 0600 temp JSON file.
   - On VMs, read secrets with `secret_get <name>` from `/opt/core/lib.sh` (instance principal).
3. **Never commit** `*.tfstate*`, `.terraform/`, `*.tfvars`, `*.pem`, `*.key`, or `backend_override.tf`.
   Do commit `.terraform.lock.hcl`.
4. **The VMs ignore `user_data` changes.** Editing `host/**` never recreates a VM. Push host changes with
   `make host-sync VM=...`. `bootstrap.sh` must stay **idempotent**: it runs on first boot, on every host-sync, and after a restore.
5. **Restore safety:** `bootstrap.sh` only runs `mkfs` on the data volume when it has *no filesystem at all*. Never weaken this check.
   Everything that must survive a restore must live on `/data`. On cloud, Docker runs with `containerd-snapshotter: false`
   (`install_docker /data/docker classic`). Docker 29's default containerd image store would put layers in `/var/lib/containerd`
   on the boot volume and break restored containers. Proven by the wipe/restore drill of 2026-10-13: see `docs/runbooks/wipe-and-restore.md`.
6. **Origin is Cloudflare-only.**
   - `core-nsg-nlb` and `core-nsg-cloud` allow 443 only from https://www.cloudflare.com/ips-v4. The NLB uses preserve-source.
   - Never add `0.0.0.0/0` ingress, and never give a VM a public IP.
   - Tailscale on cloud is outbound-only (no NSG change). The only host-firewall opening for it is mosh,
     UDP 60000–61000 on `tailscale0` (`allow_udp_on_iface`). Tailscale SSH needs no port. Bastion stays as break-glass.
7. **Never expose a first-run or setup UI publicly.**
   - On 2026-10-13, Uptime Kuma's `/setup-database` page was reachable at status.mazuryktech.com for about 4 minutes before anyone set it up. Nobody claimed it.
   - The fix: bootstrap binds Kuma to 127.0.0.1, completes setup with credentials from Vault, and only then publishes it.
   - Any new self-hosted tool behind Caddy must be initialised (or have auth configured) *before* it gets a route.
   - Kuma is public **only through its status page** (`/status/core`, which is the entry page for `/`). Never set `disableAuth`;
     `/dashboard` stays behind login. Add monitors in `kuma-provision.js` (matched by name, so it is idempotent), not by hand.
8. Keep `make plan-all` at "no changes". If the provider reorders a list (e.g. the origin cert hostnames), match the API's order.
9. Commit on a branch and push. Never force-push. Never push to `main` without the human.
   Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Naming

The pattern is `<scope>-<type>-<purpose>`: lowercase, hyphens, no numeric suffixes.
- The scope is `core` or a project slug of 12 characters or fewer.
- Shared resources go in compartment `core`. Project resources go in `projects` with tag `project=<slug>`.
- The A1 VM is **`cloud`** everywhere: `core-vm-cloud`, VNIC label and OS hostname `cloud`, Tailscale node `cloud`,
  `host/cloud/`, `VM=cloud`. It was `app` until 2026-10-16. `terraform/core/moved.tf` holds the state moves (keep it).
  One name stays: the volume attachment `core-att-app-data`, because its `display_name` is ForceNew and renaming it
  would detach `/data`. Never "fix" it.

Tags:
- `scope=core|project` and `managed-by=terraform`. Resources made by scripts use `managed-by=secret-put` or `backup-now`.

Type abbreviations:
- `vcn`, `snet`, `igw`, `natgw`, `sgw`, `rt`, `nsg`
- `vm`, `bv`, `bkp`, `nlb`, `lb`, `pip`
- `vault`, `key`, `secret`, `bucket`
- `logs`, `log`, `topic`, `alarm`, `dg`, `pol`

Hostnames are one level only: `<slug>.mazuryktech.com` or `<slug>-<svc>.mazuryktech.com`.
`api.acme.mazuryktech.com` is **not** covered by the certificate.

On the VM:
- Claude Code units are cc-orchestrator's: `cc-rc@<repo>`, `cc-agents` (tmux session `fleet`). The legacy `agent@<repo>` / tmux socket `agent-<repo>` are gone.
- the compose project is `<slug>`

## Real values (current deployment)

| Thing | Value |
|---|---|
| Reserved public IP (DNS target) | `203.0.113.10` (`core-pip-nlb`) |
| core-vm-cloud | A1.Flex 2 OCPU / 12 GB, AD-1, `10.0.2.10`, boot 50 GB + `core-bv-cloud-data` 100 GB at `/data`; OS hostname `cloud` |
| core-vm-ops | E2.1.Micro, AD-1 (the only AD that has it), `10.0.2.20`, boot 50 GB |
| Bastion | `core-bastion`, private endpoint `10.0.2.183` |
| Vault | `core-vault` (DEFAULT/shared), key `core-key-main` (SOFTWARE) |
| Cloudflare zone | `mazuryktech.com`, id supplied via the `zone_id` variable, Free plan, SSL strict |
| SMTP | `smtp.email.uk-london-1.oci.oraclecloud.com:587`, sender `noreply@mazuryktech.com` |
| Alerts | `core-topic-alerts`, which emails alerts@example.com |
| Images pinned | `lucaslorentz/caddy-docker-proxy:2.13.1-alpine`, `louislam/uptime-kuma:2.5.6-slim` |

Use `make output-<layer>` for OCIDs. Don't hard-code new OCIDs into code.

## Secrets in Vault (`core` compartment)

| Name | Created by | Used by |
|---|---|---|
| `core-secret-cf-api-token` | human (`secret-put`) | cloudflare layer provider |
| `core-secret-github-pat` | human (`secret-put`) | cloud bootstrap: `gh auth login --with-token` for `agent` (skipped if absent) |
| `core-secret-cf-origin-cert` / `-key` | cloudflare layer | cloud bootstrap, written to `/data/core/edge/certs/origin.{pem,key}` |
| `core-secret-smtp` | foundation | JSON `{host,port,username,password,from}`; also the Kuma `core-email` notification |
| `core-secret-apm-public-key` / `-private-key` | foundation | OTLP to `core-apm` |
| `core-secret-uptime-kuma-admin` | foundation (random) | ops bootstrap (Kuma first-run setup); human login |
| `core-secret-tailscale-authkey` | human (`secret-put`) | cloud bootstrap: `tailscale up --auth-key=file:…` (reusable, tagged `tag:cloud`; only needed when the node has no state; skipped if absent) |
| `core-secret-ntfy-topic` | human (`secret-put`) | cc-orchestrator `install.sh` (push topic recovery on rebuild); not read by bootstrap |

Project secrets are `<slug>-secret-*`. `secret-put` puts them in compartment `projects`.

## Free-tier limits (PAYG: going over is billed)

| Resource | Limit | Current use |
|---|---|---|
| A1 Flex | 4 OCPU / 24 GB total | 2 / 12 |
| E2.1.Micro | 2 | 1 |
| Block + boot volumes | 200 GB total, Balanced (10 VPU) only | 200 GB (**full**: no new volumes) |
| Volume backups (incl. boot) | 5 | policy keeps 3, which leaves 2 for manual backups |
| NLB | 1 | 1 |
| Flexible LB | 1 at 10 Mbps | 0 |
| Vault | DEFAULT vault, SOFTWARE keys, 150 secrets | 1 vault, 8+ secrets |
| Object Storage | 20 GB | tfstate only |
| Logging | 10 GB/month | core-log-cloud |
| Email Delivery | ~100/day free | noreply@ |
| APM | free-tier domain only (`is_free_tier = true`) | core-apm |

Before adding any resource, confirm it is Always-Free-eligible, then run `make free-tier` afterwards.
The budget `core-budget-monthly` ($1, alerts at 50%/100%, plus a 100% forecast alert) only alerts. It does not stop anything.

## Known gaps

- **Uptime Kuma history is lost on a wipe.** Its data is on the ops boot volume (`/opt/uptime-kuma/data`), which is not backed up.
  The admin login, the `core-email` SMTP notification, the standard monitors and the public status page `core` are all
  **recreated by ops bootstrap** (`host/ops/uptime-kuma/kuma-provision.js`), so only heartbeat history and hand-made monitors are lost.
- The Custom Logs plugin is NOT_SUPPORTED on the ops E2.1.Micro (Ubuntu x86). Only cloud logs reach `core-log-cloud`.
- Claude Code logs: cc-orchestrator's rsyslog rule writes `cc-rc@*` output and unit events to `/var/log/core/agent.log`, shipped by the unified agent. The Terraform log and alarm strings name `cc-rc@`/`cc-agents` (applied with `make apply-core`).
- `main` has no commits yet. Work lives on `feat/core-infra`, which is the GitHub default branch until a human sets up `main`.

## Where things live on the VMs

- `/opt/core/`: shipped host files plus `core.env` (rendered by Terraform; host-sync never overwrites it).
- `/var/log/core-bootstrap.log`: every bootstrap run.
- On cloud: `/data/{home/agent,fleet,docker,core/edge,core/tailscale,projects}`.
  - Tailscale node state is `/data/core/tailscale` (drop-in `tailscaled.service.d/10-core-state.conf`), so a restore
    from backup rejoins as the same node `cloud`.
  - The edge (Caddy) is `docker compose -f /data/core/edge/compose.yaml ...`.
- On ops: `/opt/uptime-kuma` (data + compose) and `/etc/cron.d/core-ops`.
  - Kuma provisioning: `/opt/core/uptime-kuma/kuma-{init,provision}.js`, run on every bootstrap.

## Runbooks

`docs/runbooks/`:
- `00-first-deploy`
- `wipe-and-restore`
- `fleet-repos`
- `web-projects`
- `secrets-rotation`
- `access-ssh`
- `scaling-and-limits`
- `monitoring-alerts`
- `cloudflare`
- `troubleshooting`
