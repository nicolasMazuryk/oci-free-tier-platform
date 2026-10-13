# CLAUDE.md: operating manual for this repo

This repo is the Terraform and host provisioning for **core**, one reusable OCI Always-Free
infrastructure in `uk-london-1`. It serves two purposes:

1. An **agent fleet**: Claude Code Remote Control servers, `agent@<repo>`, on `core-vm-app`.
2. **Web hosting**: `*.mazuryktech.com` through Cloudflare, served by Caddy on `core-vm-app`.

The original spec is `prompt.md`. Human docs are in `README.md`, `docs/architecture.md` and `docs/runbooks/`.

The account is **Pay-As-You-Go**. Anything that is not Always-Free is billed, so read
"Free-tier limits" below before you create anything.

## Layer map (three Terraform states, one bucket)

| Layer | Dir | State key | Lifecycle | Holds |
|---|---|---|---|---|
| foundation | `terraform/foundation` | `foundation/terraform.tfstate` | **Persistent**. Never destroy. | compartments `core` and `projects`, `core-bucket-tfstate`, `core-vault` + `core-key-main`, reserved IP `core-pip-nlb`, `core-dg-compute` / `core-pol-compute` / `core-pol-objectstorage`, `core-topic-alerts` + email sub, `core-budget-monthly`, Email Delivery (domain, `core-dkim`, `noreply@`, SMTP cred, which goes to `core-secret-smtp`), `core-apm` (keys go to `core-secret-apm-*-key`), `core-secret-uptime-kuma-admin` |
| cloudflare | `terraform/cloudflare` | `cloudflare/terraform.tfstate` | Persistent, idempotent | DNS (apex + `*` A records to the reserved IP, proxied; SPF/DKIM/DMARC DNS-only), zone TLS settings, Origin CA cert (written to `core-secret-cf-origin-cert` and `-key`) |
| core | `terraform/core` | `core/terraform.tfstate` | **Wipeable** (`make wipe` / `make restore`) | VCN/subnets/gateways/route tables, NSGs, `core-nlb`, `core-bastion`, both VMs, `core-bv-app-data`, `core-bkp-daily-3d`, logs, alarms |

- Order of dependence: foundation, then cloudflare, then core. Downstream layers read
  `terraform_remote_state` from the oci backend.
- DNS points at the **persistent reserved IP**, so wiping core never touches Cloudflare.
- The bucket is `core-bucket-tfstate`, in namespace `YOUR_OCI_NAMESPACE`. It is versioned, and old versions expire after 90 days.
- The Cloudflare provider token is read from Vault (`core-secret-cf-api-token`). It is never in a file.

## Commands (always run from the repo root)

```bash
make help                       # every target
make init-<layer>               # foundation | cloudflare | core
make plan-<layer> / apply-<layer> [ARGS='-target=...']
make plan-all                   # expect "no changes" x3 after any apply
make output-<layer> ARGS='-raw nlb_public_ip'
make ssh VM=app|ops [CMD='...'] # through core-bastion (session reused for up to 3 h)
make host-sync VM=app|ops       # rsync host/common + host/<vm> to /opt/core, re-run bootstrap.sh
make secret-put NAME=<scope>-secret-<purpose> [FILE=path]
make backup [NAME=suffix]       # manual FULL backup of core-bv-app-data (refuses past 5 backups)
make wipe                       # backup, then destroy core layer   (ASK THE HUMAN FIRST)
make restore BACKUP=<ocid>|none # recreate core; /data from backup
make free-tier                  # inventory + Always-Free check (exit 1 on violation)
make drift                      # Cloudflare IPv4 ranges vs core-nsg-app
make bootstrap                  # first-ever foundation deploy (local state, then migrate)
```

- The Makefile and `scripts/lib.sh` export `TF_VAR_tenancy_ocid` and `TF_VAR_user_ocid` from `~/.oci/config`
  (profile `DEFAULT`, or `OCI_PROFILE=`). No `*.tfvars` file is needed.
  Optional overrides are listed in `terraform.tfvars.example`.
- macOS ships bash 3.2, so scripts avoid `${arr[@]}` on empty arrays under `set -u`. Use `${arr[@]+"${arr[@]}"}`.
- The `!` shell inside Claude Code has **no TTY**. Interactive steps fail there: the `secret-put` hidden prompt,
  `make ssh` without CMD, `claude auth login`, and `fleet attach`. To put a secret from it, use the file form:
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
6. **Origin is Cloudflare-only.**
   - `core-nsg-nlb` and `core-nsg-app` allow 443 only from https://www.cloudflare.com/ips-v4. The NLB uses preserve-source.
   - Never add `0.0.0.0/0` ingress, and never give a VM a public IP.
7. **Never expose a first-run or setup UI publicly.**
   - On 2026-10-13, Uptime Kuma's `/setup-database` page was reachable at status.mazuryktech.com for about 4 minutes before anyone set it up. Nobody claimed it.
   - The fix: bootstrap binds Kuma to 127.0.0.1, completes setup with credentials from Vault, and only then publishes it.
   - Any new self-hosted tool behind Caddy must be initialised (or have auth configured) *before* it gets a route.
8. Keep `make plan-all` at "no changes". If the provider reorders a list (e.g. the origin cert hostnames), match the API's order.
9. Commit on a branch and push. Never force-push. Never push to `main` without the human.
   Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Naming

The pattern is `<scope>-<type>-<purpose>`: lowercase, hyphens, no numeric suffixes.
- The scope is `core` or a project slug of 12 characters or fewer.
- Shared resources go in compartment `core`. Project resources go in `projects` with tag `project=<slug>`.

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
- the systemd unit is `agent@<repo>`
- the tmux socket is `agent-<repo>`
- the compose project is `<slug>`

## Real values (current deployment)

| Thing | Value |
|---|---|
| Reserved public IP (DNS target) | `203.0.113.10` (`core-pip-nlb`) |
| core-vm-app | A1.Flex 2 OCPU / 12 GB, AD-1, `10.0.2.10`, boot 50 GB + `core-bv-app-data` 100 GB at `/data` |
| core-vm-ops | E2.1.Micro, AD-1 (the only AD that has it), `10.0.2.20`, boot 50 GB |
| Bastion | `core-bastion`, private endpoint `10.0.2.183` |
| Vault | `core-vault` (DEFAULT/shared), key `core-key-main` (SOFTWARE) |
| Cloudflare zone | `mazuryktech.com`, id `YOUR_CLOUDFLARE_ZONE_ID`, Free plan, SSL strict |
| SMTP | `smtp.email.uk-london-1.oci.oraclecloud.com:587`, sender `noreply@mazuryktech.com` |
| Alerts | `core-topic-alerts`, which emails alerts@example.com |
| Images pinned | `lucaslorentz/caddy-docker-proxy:2.13.1-alpine`, `louislam/uptime-kuma:2.5.6-slim` |

Use `make output-<layer>` for OCIDs. Don't hard-code new OCIDs into code.

## Secrets in Vault (`core` compartment)

| Name | Created by | Used by |
|---|---|---|
| `core-secret-cf-api-token` | human (`secret-put`) | cloudflare layer provider |
| `core-secret-github-pat` | human (`secret-put`) | app bootstrap: `gh auth login --with-token` for `agent` (skipped if absent) |
| `core-secret-cf-origin-cert` / `-key` | cloudflare layer | app bootstrap, written to `/data/core/edge/certs/origin.{pem,key}` |
| `core-secret-smtp` | foundation | JSON `{host,port,username,password,from}` |
| `core-secret-apm-public-key` / `-private-key` | foundation | OTLP to `core-apm` |
| `core-secret-uptime-kuma-admin` | foundation (random) | ops bootstrap (Kuma first-run setup); human login |

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
| Logging | 10 GB/month | core-log-app |
| Email Delivery | ~100/day free | noreply@ |
| APM | free-tier domain only (`is_free_tier = true`) | core-apm |

Before adding any resource, confirm it is Always-Free-eligible, then run `make free-tier` afterwards.
The budget `core-budget-monthly` ($1, alerts at 50%/100%, plus a 100% forecast alert) only alerts. It does not stop anything.

## Known gaps

- **Uptime Kuma data is on the ops boot volume (`/opt/uptime-kuma/data`) and is not backed up.**
  A wipe/restore or an ops VM rebuild gives you a fresh Kuma: the same admin login (from Vault), but **all monitors are lost**.
  Recreate the monitors from the list in `docs/runbooks/monitoring-alerts.md`.
- The Custom Logs plugin is NOT_SUPPORTED on the ops E2.1.Micro (Ubuntu x86). Only app logs reach `core-log-app`.
- agent@ output inside tmux is not logged. Only unit start/stop/fail events are, via rsyslog to `/var/log/core/agent.log`.
- `main` has no commits yet. Work lives on `feat/core-infra`, which is the GitHub default branch until a human sets up `main`.

## Where things live on the VMs

- `/opt/core/`: shipped host files plus `core.env` (rendered by Terraform; host-sync never overwrites it).
- `/var/log/core-bootstrap.log`: every bootstrap run.
- On app: `/data/{home/agent,fleet,docker,core/edge,projects}`.
  - The edge (Caddy) is `docker compose -f /data/core/edge/compose.yaml ...`.
- On ops: `/opt/uptime-kuma` and `/etc/cron.d/core-ops`.

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
