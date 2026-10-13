# OCI Always Free: Claude Code Agent Fleet + Shared Web Hosting

One fixed, reusable infrastructure ("**core**") with two jobs:

1. **Primary — agent fleet:** 8–10 remote Claude Code agents working in parallel, each in its own git worktree, across several repos. You drive them from the Claude iPhone app (Code tab) while away or asleep.
2. **Secondary — web hosting:** Node.js APIs and Next.js sites for those projects, served on **mazuryktech.com** through Cloudflare.

Repos and projects come and go; the infrastructure stays the same.

---

## 1. Naming convention

**Pattern:** `<scope>-<type>-<purpose>`, lowercase, hyphens, no numeric suffixes.

- **Shared infra:** scope = `core` → `core-vm-app`, `core-nlb`, `core-vault`
- **Project-specific:** scope = project slug (≤12 chars, e.g. `acme`) → `acme-bucket-uploads`, `acme-secret-db-url`
- **Tags:** `scope=core|project`, `project=<slug>` on project resources, `managed-by=rm|manual`
- **On the VM:** systemd `agent@<repo>`, tmux socket `agent-<repo>`, Remote Control session prefix `<repo>`, compose project `<slug>`
- **Hostnames (flat, one level):** `<slug>.mazuryktech.com` for sites, `<slug>-<svc>.mazuryktech.com` for APIs, `<name>.mazuryktech.com` for core tools (e.g. `status`). Stay one level deep: Cloudflare's free certificate covers `*.mazuryktech.com`, not `api.acme.mazuryktech.com`.

| Type | Abbrev | Example |
|---|---|---|
| Compartment | (plain) | `core`, `projects` |
| VCN / subnet / gateways / route table | `vcn` / `snet` / `igw`, `natgw`, `sgw` / `rt` | `core-snet-priv`, `core-natgw` |
| NSG | `nsg` | `core-nsg-app` |
| VM / boot / block volume | `vm` / `boot` / `bv` | `core-vm-app`, `core-bv-app-data` |
| Backup policy | `bkp` | `core-bkp-daily-3d` |
| Load balancers / public IP | `nlb`, `lb` / `pip` | `core-nlb`, `core-pip-nlb` |
| Vault / key / secret | `vault` / `key` / `secret` | `core-secret-github-pat`, `acme-secret-db-url` |
| Bucket | `bucket` | `acme-bucket-uploads` |
| Logs / topic / alarm | `logs`, `log` / `topic` / `alarm` | `core-topic-alerts`, `core-alarm-app-mem` |
| Dynamic group / policy / stack | `dg` / `pol` / `stack` | `core-dg-compute`, `core-stack` |

**Compartments:** `core` holds all shared infra. `projects` holds project-specific OCI resources, identified by their `<slug>-` prefix and `project` tag.

---

## 2. Core infrastructure

### Cloudflare (free plan, zone `mazuryktech.com`)

| Item | Setting |
|---|---|
| DNS `mazuryktech.com` | A → `core-nlb` IP, **proxied** (orange cloud) |
| DNS `*.mazuryktech.com` | A → `core-nlb` IP, **proxied**. Covers every project and tool hostname, so no DNS change is needed per project. |
| SSL/TLS mode | **Full (strict)** |
| Edge certificate | Universal SSL (free) for `mazuryktech.com` + `*.mazuryktech.com` |
| Origin certificate | Cloudflare **Origin CA** cert for `mazuryktech.com, *.mazuryktech.com` (15-year). Stored in Vault as `core-secret-cf-origin-cert` / `core-secret-cf-origin-key`; used by Caddy. |
| Always Use HTTPS | On |
| Email DNS | SPF TXT + DKIM CNAME for OCI Email Delivery, set to **DNS only** (grey cloud) |
| Optional | Email Routing (free) to forward e.g. `me@mazuryktech.com` to your inbox; WAF managed rules and rate limiting (free tier) |

### Compute & storage (exactly 200 GB)

| Name | Spec | Role |
|---|---|---|
| `core-vm-app` | A1 Flex 2 OCPU / 12 GB, Ubuntu 24.04 arm64, private subnet | **Agent fleet** + Caddy + web containers |
| `core-boot-app` | 50 GB | OS + 16 GB swapfile (kept off the backed-up volume) |
| `core-bv-app-data` | 100 GB → `/data` | Repos, worktrees, agent home, Docker data |
| `core-vm-ops` | E2.1.Micro 1 GB (+2 GB swap), private subnet | Uptime Kuma, cron jobs, OCI CLI scripts |
| `core-boot-ops` | 50 GB | OS + ops tools |

**Backups:** custom policy `core-bkp-daily-3d` (daily, retain 3) on `core-bv-app-data` only. That uses at most 3 of the 5 free backups and leaves 2 for manual snapshots before risky changes.

### Network

| Name | Details |
|---|---|
| `core-vcn` | 10.0.0.0/16 |
| `core-snet-pub` | 10.0.1.0/24; contains only `core-nlb` (and `core-lb` if used) |
| `core-snet-priv` | 10.0.2.0/24; both VMs, no public IPs |
| `core-igw`, `core-natgw`, `core-sgw` | Internet gateway (public subnet); NAT gateway for outbound traffic (Anthropic API, GitHub, npm); Service gateway for OCI services |
| `core-rt-pub`, `core-rt-priv` | Default route via IGW / via NAT + SGW |
| `core-nsg-app` | Inbound TCP 443 **only from Cloudflare IPv4 ranges** ([cloudflare.com/ips](https://www.cloudflare.com/ips/)), so the origin can't be reached by bypassing Cloudflare |
| `core-nsg-ops` | Inbound TCP 3001 from `core-nsg-app` |
| `core-nlb` | Listener `core-lsn-https` (443) → backend set `core-bes-https` → `core-vm-app`. Preserve source IP **on** (needed for the Cloudflare-only NSG rule), TCP health check. |
| `core-pip-nlb` | Reserved public IP for the NLB if your limits allow; otherwise the NLB's IP is stable for its lifetime |
| `core-lb` *(optional)* | Flexible LB (10 Mbps), only if you need OCI-terminated TLS via Certificates |

If `core-natgw` isn't available in your limits, place the VMs in `core-snet-pub` with public IPs and keep the same NSGs.

The agent fleet needs **no inbound ports**. Remote Control uses outbound HTTPS only.

### Services

| Name | Purpose |
|---|---|
| `core-bastion` | Admin SSH into the private VMs |
| `core-vault` + `core-key-main` (software key, free) | `core-secret-*` (GitHub PAT, SMTP, Cloudflare origin cert) and `<slug>-secret-*` |
| `core-dg-compute` + `core-pol-compute` | Instance principal: VMs can `read secret-family` in `core` and `projects` |
| Email Delivery | Approved sender `noreply@mazuryktech.com`, DKIM `core-dkim`; SMTP credentials in `core-secret-smtp` |
| `core-topic-alerts` | Email target for all alarms |
| `core-alarm-app-cpu`, `core-alarm-app-mem`, `core-alarm-app-disk`, `core-alarm-nlb-health` | Monitoring alarms |
| `core-logs` / `core-log-app` | Unified agent tails Docker logs + `journalctl -u agent@*` |
| `core-apm` | OpenTelemetry traces from web projects (`service.name=<slug>-<svc>`) |
| `core-stack` | Resource Manager (Terraform) stack owning all of the above |
| `core-budget-monthly` | $1 budget, alerts at 50% / 100%. No compartment quotas. |

---

## 3. Agent fleet (primary workload)

### How it works

Each repo gets one **Claude Code Remote Control server**, run as a systemd service. The server is started with `claude remote-control --spawn worktree --permission-mode auto`, so every session you start from your phone gets its **own git worktree** in that repo. There is no session cap.

```
iPhone Claude app ─ Code tab ─┐        (outbound HTTPS only, no open ports)
claude.ai/code (browser) ─────┤
                              ▼
                     Anthropic API (session relay)
                              ▲
core-vm-app ──────────────────┘
  agent@api-acme    → claude remote-control --spawn worktree --permission-mode auto
  agent@web-notes   → claude remote-control --spawn worktree --permission-mode auto
  agent@<repo> …      (add/remove with `fleet add|rm`)
```

- **On the go:** open the Code tab, pick a repo's session or start a new one, give it a task, and review the diff pane.
- **While you sleep:** queue tasks before bed. Push notifications arrive when a task finishes or needs a decision; enable both in `/config` (**Push when Claude decides**, **Push when actions required**).
- **Resilience:** if a session crashes, sending it a message revives it. If the network drops for about 10 minutes, the server exits; systemd restarts it, and restarting in the same directory brings back its sessions (within about 4 hours).

### Requirements & limits

- **Plan:** a claude.ai subscription (Pro/Max). Remote Control doesn't work with API keys, and it doesn't work with `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` (those tokens are model-only). Sign in on the VM once with `claude auth login` as the `agent` user.
- **Usage:** 8–10 parallel agents use subscription limits quickly. Max is realistically needed, and overnight queues may stall until the usage window resets.
- **Compute reality (2 OCPU / 12 GB):** agents spend most of their time waiting on the model, so 8–10 sessions fit. The bottleneck is concurrent heavy tool runs (`tsc`, test suites, `next build`) on 2 cores; those slow down rather than fail. The 16 GB swap absorbs memory spikes. Rough RAM: about 0.3–0.5 GB per session idle, plus transient build spikes.
- **Priority:** agent services get `CPUWeight=200` (default is 100). This is a priority under contention, not a cap. Docker containers stay unlimited.

### Access

- **Full machine access:** the `agent` user has passwordless sudo and is in the `docker` group. Agents can manage containers, deploy web projects, read `/data/projects`, and use the instance principal.
- **Permission mode:** always **auto** (`--permission-mode auto` on every server, plus `"defaultMode": "auto"` in `~/.claude/settings.json`). Auto mode's classifier still blocks a few high-risk actions by default, such as production deploys and fetching credentials from the instance metadata service. If an agent hits one of these, you can permit it in that session's conversation or allow the host in the `autoMode.environment` setting.
- **Disk:** use pnpm (shared content-addressable store), so N worktrees don't each duplicate `node_modules`.

### GitHub access: personal repos only

- **One fine-grained PAT**, stored in Vault as `core-secret-github-pat`:
  - **Resource owner:** `nicolasMazuryk`. A fine-grained token covers only one owner, so organization repos are excluded by design.
  - **Repository access:** *All repositories*. This covers every current and future repo in your personal account.
  - **Permissions:**
    - Contents: read/write
    - Pull requests: read/write
    - Issues: read/write
    - Workflows: read/write (only if agents edit `.github/workflows`)
    - Metadata: read
- **HTTPS only:**
  - Configure with `gh auth login --with-token`, then `gh auth setup-git`, then `gh config set git_protocol https`.
  - **No SSH keys and no classic PATs on the VM.** Either would reach organization repos.
- Clone fleet repos with `https://github.com/nicolasMazuryk/<repo>.git`.

---

## 4. Web hosting (secondary workload)

```
Visitor ─HTTPS─▶ Cloudflare edge (DNS, CDN, WAF, Universal SSL)
                   │  *.mazuryktech.com, proxied
                   ▼ HTTPS (Full strict, Origin CA cert)
core-nlb :443  (NSG: Cloudflare IPs only)
                   │
core-vm-app
  └─ core-edge: caddy-docker-proxy (Origin cert, routes from container labels)
        │  docker network "edge"
        ├─ acme-api  → acme-api.mazuryktech.com
        ├─ acme-web  → acme.mazuryktech.com
        └─ …
  └─ status.mazuryktech.com → core-vm-ops:3001 (Uptime Kuma)
```

Starting a container with Caddy labels routes it; stopping it removes the route. The wildcard DNS record and wildcard Origin cert already cover every new hostname, so adding a project needs **no DNS or certificate step**.

Apps should read the real client IP from the `CF-Connecting-IP` header.

**Other domains** (e.g. a project's own domain): add the domain to Cloudflare, proxy it to the same NLB IP, issue an Origin CA cert for it, and add it to Caddy alongside the main one.

---

## 5. Host layout & bootstrap (`core-vm-app`)

```
/data                          ← core-bv-app-data (daily backup)
├── home/agent/                ← agent user home (~/.claude, ~/.local/bin/claude, pnpm store)
├── fleet/<repo>/              ← main clone per repo; session worktrees created by Claude Code
├── docker/                    ← Docker data-root
├── core/edge/                 ← Caddy compose, Caddyfile, certs/ (Origin CA cert + key)
└── projects/<slug>/           ← deployed web projects
```

### Bootstrap (one time, as an admin user)

```bash
# data volume
sudo mkfs.ext4 -L data /dev/oracleoci/oraclevdb            # first time only
echo 'LABEL=data /data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /data && sudo mount -a

# 16 GB swap on the boot volume
sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# base tools + Docker
sudo apt-get update && sudo apt-get install -y git tmux gh jq build-essential
curl -fsSL https://get.docker.com | sudo sh
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{ "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" } }
EOF
sudo systemctl restart docker
sudo docker network create edge
sudo mkdir -p /data/core/edge/certs /data/projects /data/fleet

# Cloudflare Origin CA cert from Vault → /data/core/edge/certs/origin.pem + origin.key (chmod 600)

# agent user: full access (docker + passwordless sudo)
sudo useradd -m -d /data/home/agent -s /bin/bash -G docker agent
echo 'agent ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/agent && sudo chmod 440 /etc/sudoers.d/agent
sudo chown agent:agent /data/fleet /data/projects
sudo -iu agent bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
```

Then, as `agent`:

```bash
# Node (fnm/nvm) + pnpm
corepack enable

# GitHub: fine-grained PAT from Vault, HTTPS only
echo "$PAT" | gh auth login --with-token
gh auth setup-git
gh config set git_protocol https
git config --global user.name "…"
git config --global user.email "…"

# Claude Code: full login (not setup-token), then accept the one-time Remote Control prompt
claude auth login
mkdir -p ~/.claude && echo '{ "permissions": { "defaultMode": "auto" } }' > ~/.claude/settings.json
```

On Oracle's Ubuntu image, also allow 443 in the host iptables rules if it's rejected.

### `/etc/systemd/system/agent@.service`

```ini
[Unit]
Description=Claude Code agent server for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=agent
WorkingDirectory=/data/fleet/%i
Environment=PATH=/data/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/tmux -L agent-%i new-session -d -s main \
  "claude remote-control --spawn worktree --permission-mode auto --remote-control-session-name-prefix %i"
ExecStop=/usr/bin/tmux -L agent-%i kill-server
Restart=always
RestartSec=30
CPUWeight=200

[Install]
WantedBy=multi-user.target
```

Each repo gets its own tmux socket, so the services are independent and you can attach to any one over Bastion SSH.

### `/usr/local/bin/fleet`

```bash
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-}; name=${2:-}
case "$cmd" in
  add)    sudo -u agent git clone "https://github.com/nicolasMazuryk/$name.git" "/data/fleet/$name"
          sudo systemctl enable --now "agent@$name"
          echo "First run: 'fleet attach $name' and accept the workspace trust prompt (Ctrl-b d to detach)" ;;
  rm)     sudo -u agent git -C "/data/fleet/$name" worktree list
          read -rp "Unpushed work above will be lost. Remove $name? [y/N] " ok; [[ $ok == y ]] || exit 1
          sudo systemctl disable --now "agent@$name"
          sudo rm -rf "/data/fleet/$name" ;;
  ls)     systemctl list-units 'agent@*' --no-legend ;;
  attach) sudo -u agent tmux -L "agent-$name" attach ;;
  logs)   journalctl -u "agent@$name" -f ;;
  *)      echo "usage: fleet add|rm|attach|logs <repo> | fleet ls"; exit 1 ;;
esac
```

`fleet add` takes just the repo name and always clones from your personal account.

### `/data/core/edge/compose.yaml`

```yaml
name: core-edge
services:
  caddy:
    image: lucaslorentz/caddy-docker-proxy:latest   # pin a version tag
    restart: unless-stopped
    ports: ["443:443"]
    environment:
      CADDY_INGRESS_NETWORKS: edge
      CADDY_DOCKER_CADDYFILE_PATH: /etc/caddy/Caddyfile
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./certs:/certs:ro
      - caddy_data:/data
    networks: [edge]
networks:
  edge: { external: true }
volumes:
  caddy_data:
```

### `/data/core/edge/Caddyfile`

```
(cf_tls) {
    tls /certs/origin.pem /certs/origin.key
}

status.mazuryktech.com {
    import cf_tls
    reverse_proxy 10.0.2.20:3001
}
```

The `cf_tls` snippet makes Caddy serve the Cloudflare Origin cert instead of requesting Let's Encrypt certificates. Projects pull it in with one label.

---

## 6. Lifecycle

### Agent fleet

| Action | Command |
|---|---|
| Add a repo | `fleet add api-acme`, then `fleet attach api-acme` once to accept trust |
| New agent | Claude app → Code → start a session on that repo (it gets its own worktree) |
| Remove a repo | `fleet rm api-acme` (shows worktrees first so you can check for unpushed work) |
| Status / logs | `fleet ls`, `fleet logs <repo>` |
| Clean stale worktrees | `sudo -u agent git -C /data/fleet/<repo> worktree prune` |

### Web projects

Each repo ships a `Dockerfile` (listening on 3000, with `/health`) and a `compose.yaml`:

```yaml
name: acme
services:
  api:
    build: .
    restart: unless-stopped
    env_file: .env
    networks: [edge]
    labels:
      caddy: acme-api.mazuryktech.com
      caddy.import: cf_tls
      caddy.reverse_proxy: "{{upstreams 3000}}"
  web:                       # optional Next.js (output: "standalone")
    build: ./web
    restart: unless-stopped
    networks: [edge]
    labels:
      caddy: acme.mazuryktech.com
      caddy.import: cf_tls
      caddy.reverse_proxy: "{{upstreams 3000}}"
networks:
  edge: { external: true }
```

| Action | Steps |
|---|---|
| Add | Create `acme-secret-*` in Vault → `git clone` to `/data/projects/acme` → render `.env` from Vault → `docker compose up -d --build` → add an Uptime Kuma monitor for `https://acme-api.mazuryktech.com/health` |
| Update | `git pull && docker compose up -d --build` (agents can do this themselves) |
| Remove | `docker compose down -v && rm -rf /data/projects/acme`, then delete OCI resources tagged `project=acme` |

---

## 7. Guardrails

- The $1 budget only alerts; with no quotas, check every new resource shows **Always Free-eligible**.
- Volume backups beyond 5 are billed on a paid account; the policy keeps 3.
- Remote Control stores session transcripts on Anthropic's servers while connected; code execution and files stay on the VM.
- **Cloudflare free-plan limits:** requests time out after about 100 s (affects long-running API calls; prefer streaming/SSE or async jobs), and uploads are capped at 100 MB per request. WebSockets work.
- **Cloudflare IP ranges** change rarely; have a weekly cron on `core-vm-ops` that diffs [cloudflare.com/ips](https://www.cloudflare.com/ips/) against `core-nsg-app` and alerts to `core-topic-alerts`.
- Outbound port 25 is blocked; use Email Delivery on 587 with SPF/DKIM in Cloudflare DNS.
- Everything is arm64, which happens automatically when projects are built on the VM.