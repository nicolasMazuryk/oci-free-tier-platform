# Troubleshooting

Start with:

```bash
make plan-all            # drift?
make free-tier           # anything billable?
make ssh VM=cloud CMD='sudo grep "^\[" /var/log/core-bootstrap.log | tail -20'
```

## Sites down (Cloudflare 52x, `core-alarm-nlb-health`)

1. Check the edge on cloud:
   `make ssh VM=cloud CMD='sudo docker ps; sudo docker logs --tail 50 core-edge-caddy-1'`
2. Check locally:
   `make ssh VM=cloud CMD='curl -sk --resolve mazuryktech.com:443:127.0.0.1 https://mazuryktech.com'`
   - If that fails, run `make host-sync VM=cloud`. That re-renders the Caddyfile, reinstalls the cert from Vault and restarts Caddy.
3. Check the certs:
   `sudo ls -l /data/core/edge/certs` (both files should be 0600 and non-empty).
   If they're missing, bootstrap logs `WARN: could not read origin cert`. Check the Vault policy and the instance principal.
4. Check NLB health:
   `oci nlb backend-set-health get --network-load-balancer-id $(make -s output-core ARGS='-raw nlb_id') --backend-set-name core-bes-https`
5. Check the host firewall: `sudo iptables -S INPUT | grep 443`. If the rule is missing, re-run bootstrap.
6. Is this a 522 right after a Cloudflare IP change? Run `make drift`, then `make apply-core`.

## status.mazuryktech.com

| Symptom | Cause / fix |
|---|---|
| 502 | Kuma down or still starting (`make ssh VM=ops CMD='sudo docker ps'`), or `core-nsg-ops` / iptables 3001 |
| redirects to `/setup` or `/setup-database` | **Treat as a security incident.** Kuma was published before setup. Block it at once in Caddy on cloud: `sudo sed -i 's#reverse_proxy 10.0.2.20:3001#respond "maintenance" 503#' /data/core/edge/Caddyfile && sudo docker compose -f /data/core/edge/compose.yaml restart caddy`. Then run `make host-sync VM=ops` (it sets Kuma up from Vault on localhost), then `make host-sync VM=cloud` |
| ops bootstrap `FATAL: uptime-kuma setup failed` | Kuma stays local-only, so it is safe. Check `sudo docker logs core-status-uptime-kuma-1` and re-run `make host-sync VM=ops` |
| `/` goes to `/dashboard` instead of `/status/core`, or monitors are missing | Provisioning failed. Look for `uptime-kuma provisioning attempt` lines in `/var/log/core-bootstrap.log`, then run `make host-sync VM=ops` |

## Agent fleet

| Symptom | Fix |
|---|---|
| Claude Code / Remote Control problems (`cc-rc@<repo>`, Agent View, settings) | Owned by cc-orchestrator: its `docs/runbooks/troubleshooting.md`. From the Mac: `fleet logs cloud <repo>` |
| `agent@<repo>` or `fleet` still on the VM | Legacy (pre cc-orchestrator Phase 4b). `make host-sync VM=cloud` removes them (bootstrap step 5) |
| tmux fails with `missing or unsuitable terminal: xterm-ghostty` (or `xterm-kitty`, etc.) | The VM has no terminfo for your terminal. `make ssh` falls back to `xterm-256color` automatically. Manual workaround: `TERM=xterm-256color tmux …` |
| `git push` fails with 403 | PAT expired or missing permissions. Rotate `core-secret-github-pat`, then `make host-sync VM=cloud`. Check with `sudo -iu agent gh auth status` |
| Everything slow | 2 OCPUs shared with builds. Check `top`, `core-alarm-cloud-cpu`/`-mem`, swap use (`free -m`) |
| Disk full | `sudo docker system df`, `sudo -iu agent pnpm store prune`, `git -C /data/fleet/<repo> worktree prune` |

## Terraform

| Error | Fix |
|---|---|
| `Compartment {core} does not exist or is not part of the policy compartment subtree` | IAM propagation lag on the first apply. Re-run |
| `Out of host capacity` (A1) | Retry later, or `cloud_ad_index = 1|2` |
| cloudflare plan: `Vault secret core-secret-cf-api-token not found` | `make secret-put NAME=core-secret-cf-api-token` |
| `Error acquiring the state lock` | Another apply is running. If it is stale: `terraform -chdir=terraform/<layer> force-unlock <id>` (be sure first) |
| (host) `RWLayer of container ... is unexpectedly nil` on `docker compose up` | Docker data whose layers live outside `/data` (containerd image store). Cloud bootstrap now disables it and recreates `core-edge` automatically. For a project container: `docker compose rm -fs && docker compose up -d --build` |
| Perpetual diff on `cloudflare_origin_ca_certificate.hostnames` | Keep the list in API order: `["*.domain", "domain"]` |
| Need an old state | Bucket versioning: `oci os object list-object-versions -bn core-bucket-tfstate --prefix core/` |

## Logs or metrics missing

- **`core-log-cloud` empty:**
  1. On cloud, check `sudo tail /var/log/unified-monitoring-agent/unified-monitoring-agent.log`. You should see "following tail of ..." and `response 200`.
  2. The config lives at `/etc/unified-monitoring-agent/conf.d/fluentd_config/fluentd.conf`.
  3. Records dated 1970 mean time parsing is broken. Check `time_format` in the docker source.
- **Disk metric missing:**
  `systemctl status core-disk-metric.timer; sudo /usr/local/bin/core-disk-metric`. A 404 or NotAuthorized there points at the policy (`use metrics`).
- **Drift cron fails with NotAuthorizedOrNotFound on NSG rules:**
  Listing rules needs `use network-security-groups`, which is in `core-pol-compute`.

## Tailscale / mosh

| Symptom | Fix |
|---|---|
| `ssh agent@cloud` hangs or `cloud` does not resolve | `make ssh VM=cloud CMD='tailscale status'`. `NeedsLogin`: put a valid key in `core-secret-tailscale-authkey`, then `make host-sync VM=cloud`. `grep -i tailscale /var/log/core-bootstrap.log` shows the last attempt |
| Node joined as `cloud-1` | An old `cloud` machine still exists. Delete the stale one in the admin console, rename the new one to `cloud` |
| `tailscale up` fails with "requested tags are invalid or not permitted" | The tailnet policy has no `tagOwners` entry for `tag:cloud`, or the key is not tagged `tag:cloud` |
| `mosh agent@cloud`: "Nothing received from server" | `sudo iptables -S INPUT \| grep 60000` must show the `tailscale0` rule before the REJECT. Re-run `make host-sync VM=cloud` |

## Bastion / SSH

See [access-ssh](access-ssh.md).
