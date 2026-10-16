# Monitoring and alerts

Everything publishes to **`core-topic-alerts`**, which emails alerts@example.com.
The subscription must be confirmed by clicking the link in the first email.

## Alarms (`terraform/core/observability.tf`)

| Alarm | Query | Fires after | Response |
|---|---|---|---|
| `core-alarm-cloud-cpu` | `oci_computeagent CpuUtilization{cloud}.mean() > 90` | 15 min | Concurrent builds/tests. `make ssh VM=cloud CMD='top -bn1 \| head -20'`. Fewer parallel agents, or scale A1 (see [scaling](scaling-and-limits.md)) |
| `core-alarm-cloud-mem` | `MemoryUtilization{cloud}.mean() > 90` | 10 min | `free -m; ps aux --sort=-rss \| head`. Stop idle containers or agents |
| `core-alarm-cloud-disk` | `core_custom disk_used_pct.max() > 85` (all hosts/mounts) | 5 min | Check the `host` and `mount` dimensions. `docker system prune`, `git worktree prune`, `pnpm store prune`, old `/data/projects` |
| `core-alarm-nlb-health` | `oci_nlb HealthyBackends{core-nlb}.min() < 1` | 5 min | **All sites are down.** See [troubleshooting](troubleshooting.md) for Caddy/edge |
| `core-alarm-metrics-absent` | `disk_used_pct{mount="/"}.absent()` | 15 min | A VM is down, or `core-disk-metric.timer` stopped: `systemctl status core-disk-metric.timer` |

Notes:
- Repeat notifications go out every 4 h while an alarm is firing.
- Check status with:
  `oci monitoring alarm-status list-alarms-status --compartment-id <core> --all --query 'data[].{n:"display-name",s:status}' --output table`
- Other sources that publish to the topic:
  - the weekly **Cloudflare IP drift** cron on ops (Mondays 06:17 UTC)
  - the budget alerts (emailed directly)
  - anything that calls `notify "<title>" "<body>"` from `/opt/core/lib.sh`

## Custom metric

`core-disk-metric.timer` runs every 5 min on both VMs. It posts `core_custom/disk_used_pct` with dimensions `resourceId`, `host`, `mount`:
- app: `/` and `/data`
- ops: `/`

It uses the instance principal and the `use metrics` policy.

## Logs: `core-logs / core-log-cloud` (30 days)

The unified agent config `core-uac-cloud` (cloud only; the plugin is unsupported on the ops Micro) tails three sources:

| Source | File |
|---|---|
| Docker containers | `/data/docker/containers/*/*-json.log` (JSON; `time` parsed) |
| agent@* unit events | `/var/log/core/agent.log` (rsyslog rule `/etc/rsyslog.d/30-core-agent.conf`) |
| Bootstrap runs | `/var/log/core-bootstrap.log` |

- The agent flushes every 180 s. A new config can take up to about 10 minutes to reach the host.
- Search from the CLI:
  ```bash
  C=<core-compartment>; LG=$(make -s output-core ARGS='-raw log_group_id'); L=$(make -s output-core ARGS='-raw cloud_log_id')
  oci logging-search search-logs --search-query "search \"$C/$LG/$L\" | sort by datetime desc" \
    --time-start $(date -u -v-1H +%FT%TZ) --time-end $(date -u +%FT%TZ) --limit 20
  ```

## Uptime Kuma (https://status.mazuryktech.com)

**Public view:** `https://status.mazuryktech.com/` redirects to the public status page **`/status/core`**, titled "mazuryktech status". No login is needed.

**Admin:** `/dashboard` still requires login. Auth is never disabled. The user is `admin`; get the password with:
```bash
oci secrets secret-bundle get-secret-bundle-by-name --vault-id $(make -s output-foundation ARGS='-raw vault_id') \
  --secret-name core-secret-uptime-kuma-admin --query 'data."secret-bundle-content".content' --raw-output | base64 -d
```

**Everything is provisioned by code.** On every ops bootstrap, `host/ops/uptime-kuma/kuma-provision.js` logs in over socket.io and ensures the following. Items are matched by name or slug, so a rerun never creates duplicates.

| Item | Detail |
|---|---|
| Notification `core-email` | SMTP via OCI Email Delivery (`core-secret-smtp`, port 587 STARTTLS), from `noreply@mazuryktech.com` to `ALERTS_EMAIL` (in core.env). It is the default and applies to all monitors |
| Monitor `mazuryktech.com` | keyword `core edge: ok` on `https://mazuryktech.com`, every 60 s (Cloudflare, then NLB, then Caddy) |
| Monitor `status.mazuryktech.com` | HTTP 2xx on `https://status.mazuryktech.com/status/core`, every 60 s |
| Monitor `core-vm-cloud origin :443 (private)` | TCP to `10.0.2.10:443` from ops, every 60 s. This bypasses Cloudflare and the NLB, and is allowed by NSG rule "uptime kuma origin probe from ops" |
| Monitor `GitHub` | HTTP 2xx on `https://github.com`, every 300 s (agent dependency) |
| Monitor `Anthropic API` | `https://api.anthropic.com`; any 200–499 counts as reachable; every 300 s |
| Status page `core` | groups Sites / Origin / Dependencies, published, shows cert expiry, auto-refresh 300 s |
| Settings | `entryPage = statusPage-core`, `disableAuth = false` |

How the pieces relate:
- **Add a monitor permanently:** add it to `wanted()` in `kuma-provision.js`, then run `make host-sync VM=ops`.
- **Monitors added in the UI** work, but they are not recreated after a wipe.
- **Existing monitors are not modified.** Provisioning only creates missing ones. To change a provisioned monitor's settings, edit it in the UI *and* in the script.
- **Kuma alerts and OCI alarms are separate.** Kuma emails come through `core-email`. They are independent of `core-topic-alerts`.

**Known gap:** Kuma data is on the ops boot volume and is not backed up. After a wipe/restore or an ops rebuild, the login, notification, monitors and status page come back automatically. **Heartbeat history** and any monitors added by hand are lost.

**Security:** Kuma is only published after first-run setup is complete. See CLAUDE.md invariant 7. Never put another unauthenticated or first-run UI behind Caddy, and never set Kuma's `disableAuth`.

## Budget

`core-budget-monthly` is $1 per month on the whole tenancy. It alerts on ACTUAL spend at 50% and 100%, and on FORECAST at 100%.

Any alert means something non-free exists:
1. Run `make free-tier`.
2. Look at Billing, then Cost Analysis.
