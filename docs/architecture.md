# Architecture

## Goals

- **One fixed infrastructure ("core")** that outlives repos and projects. Adding a repo or a site never changes Terraform.
- **Always-Free only.** This is a PAYG tenancy, so `make free-tier` and the $1 budget catch mistakes.
- **Wipe and restore.** The compute/network layer can be destroyed and rebuilt from code plus one volume backup, without touching DNS, secrets or state.

## Terraform layers

```
terraform/foundation  (persistent)  ->  terraform/cloudflare (persistent)  ->  terraform/core (wipeable)
        |  outputs via terraform_remote_state (oci backend, bucket core-bucket-tfstate)  |
```

| Layer | Why separate |
|---|---|
| foundation | Holds things that must survive a wipe: the state bucket itself, Vault + key + secrets, the reserved public IP that DNS points at, IAM, alerting topic, budget, Email Delivery, APM. `prevent_destroy` is set on bucket/vault/key/IP. Bootstrapped with local state, then migrated into the bucket it creates (`make bootstrap`). |
| cloudflare | DNS + TLS. It depends only on the reserved IP, so the NLB can be destroyed and recreated freely. The provider token comes from Vault. |
| core | Everything that costs nothing to recreate: VCN, NSGs, NLB, Bastion, VMs, data volume, backup policy, logs, alarms. |

State locking is native to the oci backend. The bucket is versioned, and previous versions expire after 90 days.

## Network

| Name | CIDR / detail |
|---|---|
| `core-vcn` | 10.0.0.0/16, DNS label `core` |
| `core-snet-pub` | 10.0.1.0/24, route `core-rt-pub` (0/0 via `core-igw`); contains only `core-nlb` (10.0.1.138) |
| `core-snet-priv` | 10.0.2.0/24, no public IPs, route `core-rt-priv` (0/0 via `core-natgw`, OSN via `core-sgw`); app 10.0.2.10, ops 10.0.2.20, Bastion endpoint 10.0.2.183 |
| `core-sl-base` | security list on both subnets: egress all and ICMP type 3. **All ingress is in NSGs.** |

NSGs:

| NSG | Ingress |
|---|---|
| `core-nsg-nlb` (on the NLB) | TCP 443 from each Cloudflare IPv4 range (15 rules, fetched from cloudflare.com/ips-v4 at plan time). Egress 443 to `core-nsg-cloud`. |
| `core-nsg-cloud` | TCP 443 from Cloudflare ranges (the NLB preserves the source IP); TCP 443 from `core-nsg-nlb` (health checks); TCP 443 from `core-nsg-ops` (Kuma origin probe); TCP 22 from the Bastion endpoint /32 |
| `core-nsg-ops` | TCP 3001 from `core-nsg-cloud` (Caddy proxies status.*); TCP 22 from the Bastion endpoint /32 |

Host firewall: Oracle's Ubuntu image ends `INPUT` with REJECT. Bootstrap inserts ACCEPT rules for 443 (app) and 3001 (ops), both live and in `/etc/iptables/rules.v4`.

### Request path (web)

```
browser --TLS (Universal SSL)--> Cloudflare edge --TLS (Full strict, Origin CA)--> 203.0.113.10:443
  core-nlb listener core-lsn-https (TCP) -> backend set core-bes-https (preserve source, TCP health check :443)
  -> core-vm-cloud:443 -> docker-proxy -> caddy (core-edge) -> container on network "edge"
```

- Caddy serves the Origin CA cert from `/data/core/edge/certs` for every site via the `(cf_tls)` snippet.
- Sites are created from container labels (caddy-docker-proxy).
- The base `Caddyfile` (rendered from `host/cloud/edge/Caddyfile.tmpl`) defines three sites:
  - the apex, which answers 200
  - `status.` proxied to the ops VM
  - a `*.` catch-all that returns 404
- Hitting the NLB IP directly times out, because only Cloudflare ranges are allowed.
- Apps should read the client IP from `CF-Connecting-IP`.

### Agent path

```
iPhone Claude app / claude.ai/code <-> Anthropic relay <- outbound HTTPS (NAT) <- agent@<repo> on core-vm-cloud
```

No inbound ports are involved. Each repo is one systemd `agent@<repo>` running
`claude remote-control --spawn worktree --permission-mode auto` in tmux socket `agent-<repo>`.
Each session started from the phone gets its own worktree under `/data/fleet/<repo>`.

### Tailnet access

```
Mac / iPhone --Tailscale (WireGuard, outbound from both ends, DERP or direct)--> core-vm-cloud = node `cloud`, tag:cloud
```

- Tailscale SSH (users `agent`, `ubuntu`) and mosh (UDP 60000–61000, allowed on `tailscale0` only) are the daily path.
  Bastion is break-glass. No NSG rule, public IP or open port is involved.
- The tailnet policy (owned by cc-orchestrator, `config/tailscale/policy.hujson`) has no rule with `src: tag:cloud`:
  the VM cannot open connections to the Mac or iPhone.
- Node state is on `/data/core/tailscale`, so it survives a wipe/restore from backup.

## Compute and storage

| Resource | Spec |
|---|---|
| `core-vm-cloud` | VM.Standard.A1.Flex 2 OCPU / 12 GB, Ubuntu 24.04 aarch64, AD-1, boot 50 GB (OS + 16 GB swapfile) |
| `core-bv-cloud-data` | 100 GB paravirtualized at `/dev/oracleoci/oraclevdb`, label `data`, mounted at `/data`. Backed up daily by `core-bkp-daily-3d` (incremental, keep 3, 03:00 UTC) |
| `core-vm-ops` | VM.Standard.E2.1.Micro (AD-1 only), Ubuntu 24.04 x86, boot 50 GB + 2 GB swap. Runs Uptime Kuma, the weekly CF drift cron, and the disk metric |

`/data` layout on cloud:

| Path | Contents |
|---|---|
| `home/agent` | Claude login and `~/.claude`, gh auth, pnpm store |
| `fleet/<repo>` | the main clone, plus worktrees |
| `docker` | Docker data-root |
| `core/edge` | compose file, Caddyfile and certs |
| `projects/<slug>` | deployed web projects |

Because all of this is on the volume, restoring the volume from a backup brings back the Claude login, repos and containers.

Instance options:
- Legacy IMDS v1 is disabled.
- These Oracle Cloud Agent plugins are enabled:
  - Compute Instance Monitoring (CPU and memory metrics)
  - Custom Logs Monitoring (cloud only; not supported on the Micro)
  - Bastion

## Host provisioning

- Cloud-init is built in `terraform/core/host.tf`. It writes `host/common/*` plus `host/<role>/*` (gzip+base64) and a rendered `core.env` to `/opt/core/`, then runs `bootstrap.sh`.
- The VMs have `ignore_changes = [metadata["user_data"]]`. Later changes go through `make host-sync`, which uses rsync over Bastion and re-runs the bootstrap.

`host/cloud/bootstrap.sh` is idempotent. In order, it:
0. Renames old `core.env` keys (`APP_IP` → `CLOUD_IP`, `ROLE="app"` → `"cloud"`) and pins the OS hostname `cloud`:
   `/etc/hosts` `127.0.1.1 cloud cloud`, `hostnamectl set-hostname cloud`, and the cloud-init drop-in
   `/etc/cloud/cloud.cfg.d/99-zz-core-hostname.cfg` (`hostname: cloud`), so every boot keeps it. Claude Code shows this
   name as the Remote Control device name.
1. Waits for the data volume, runs `mkfs` **only if there is no filesystem**, and mounts it at `/data`.
2. Sets up the 16 GB swap and installs packages.
3. Installs the OCI CLI (venv at `/opt/oci-cli`) and Node 24 + pnpm.
4. Installs Docker with data-root `/data/docker`, with the containerd image store **disabled** (overlay2, so layers live on `/data` and survive a restore), and creates the `edge` network.
5. Creates the `agent` user, or recreates it with the same uid/gid if `/data/home/agent` already exists (the restore case). The user gets passwordless sudo and is in the docker group.
6. Installs Claude Code and sets settings to `defaultMode: auto`.
7. Logs in to gh from `core-secret-github-pat`, if that secret exists.
8. Installs Tailscale (state on `/data/core/tailscale`), joins as `cloud` / `tag:cloud` from `core-secret-tailscale-authkey`
   (only when the node has no state yet), and allows mosh on `tailscale0`.
9. Installs `agent@.service` and `fleet`, and re-enables `agent@<repo>` for every clone in `/data/fleet`.
10. Installs the Origin cert from Vault, renders the Caddyfile, and brings up `core-edge`.
11. Sets up the rsyslog rule, logrotate, and the disk-metric timer.

`host/ops/bootstrap.sh`:
1. Sets up swap and installs the OCI CLI and Docker.
2. Brings up **Uptime Kuma, safely**:
   - It first runs bound to 127.0.0.1.
   - The script selects SQLite (`/setup-database`) and creates the admin from `core-secret-uptime-kuma-admin` over socket.io (`host/ops/uptime-kuma/kuma-init.js`).
   - Only after that does it publish on 0.0.0.0:3001.
   - It counts as initialised if the `user` table has at least one row.
   - `kuma-provision.js` then ensures (idempotently, by name) the SMTP notification `core-email`, five monitors (apex keyword, the status page itself, a private TCP probe of cloud:443, GitHub, Anthropic API), the public status page `core`, and `entryPage = statusPage-core`. Auth stays on.
3. Installs the weekly `core-cf-ip-drift` cron and the disk-metric timer.

## Identity and secrets

- Dynamic group `core-dg-compute` matches all instances in compartment `core`.
- Policy `core-pol-compute` lets them:
  - read secret-family in core and projects
  - use metrics in core
  - use ons-topics in core
  - read virtual-network-family and use network-security-groups in core
  - use log-content in core
  - read instances in core
  - manage object-family in projects
- `core-pol-objectstorage` lets the Object Storage service run the bucket lifecycle rule.
- Secrets are in `core-vault`, a DEFAULT (shared, free) vault, encrypted with `core-key-main` (AES-256, SOFTWARE). See CLAUDE.md for the inventory.
- Terraform-generated secrets (SMTP, APM, origin cert/key, Kuma admin) are also in the private state bucket by necessity.

## Observability

| What | Where |
|---|---|
| CPU / memory | `oci_computeagent` metrics, which feed `core-alarm-cloud-cpu` (>90% for 15 min) and `core-alarm-cloud-mem` (>90% for 10 min) |
| Disk usage | custom metric `core_custom/disk_used_pct{host,mount}`, posted every 5 min by `core-disk-metric.timer` on both VMs. It feeds `core-alarm-cloud-disk` (>85%) and `core-alarm-metrics-absent` (nothing for 15 min) |
| NLB | `oci_nlb HealthyBackends < 1` feeds `core-alarm-nlb-health` |
| Logs | `core-logs/core-log-cloud` (30 days). The unified agent `core-uac-cloud` tails Docker json logs, `/var/log/core/agent.log` (agent@* unit events via rsyslog) and `/var/log/core-bootstrap.log` |
| Uptime | Uptime Kuma: the public status page at https://status.mazuryktech.com (`/status/core`). The admin `/dashboard` needs login. Kuma emails alerts through `core-email` (Email Delivery) |
| Traces | `core-apm` (free tier). OTLP endpoint is `make output-foundation ARGS='-raw apm_data_upload_endpoint'`, auth key from `core-secret-apm-private-key` |
| Alert fan-out | every alarm, the drift cron and `notify` in `/opt/core/lib.sh` publish to `core-topic-alerts`, which emails the alerts address |
| Spend | `core-budget-monthly`: $1 on the whole tenancy, actual 50%/100% and forecast 100% |

## Known gaps / trade-offs

- **Kuma history is not backed up.** It is on the ops boot volume. After a wipe/restore or an ops rebuild, bootstrap recreates the login, notification, monitors and status page. Heartbeat history and monitors added by hand are lost.
- The ops VM ships no logs, because the Custom Logs plugin is unsupported on the E2.1.Micro.
- The `agent` user has passwordless sudo and docker by design (spec). Agents can do anything the instance principal allows.
- The Bastion allows `0.0.0.0/0` as session clients. Sessions still need the `~/.ssh/oci_core` key. You can narrow this with `bastion_client_cidrs`.
