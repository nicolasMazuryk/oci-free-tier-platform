# Monitoring and alerts

Everything publishes to **`core-topic-alerts`**, which emails alerts@example.com.
The subscription must be confirmed by clicking the link in the first email.

## Alarms (`terraform/core/observability.tf`)

| Alarm | Query | Fires after | Response |
|---|---|---|---|
| `core-alarm-app-cpu` | `oci_computeagent CpuUtilization{app}.mean() > 90` | 15 min | Concurrent builds/tests. `make ssh VM=app CMD='top -bn1 \| head -20'`. Fewer parallel agents, or scale A1 (see [scaling](scaling-and-limits.md)) |
| `core-alarm-app-mem` | `MemoryUtilization{app}.mean() > 90` | 10 min | `free -m; ps aux --sort=-rss \| head`. Stop idle containers or agents |
| `core-alarm-app-disk` | `core_custom disk_used_pct.max() > 85` (all hosts/mounts) | 5 min | Check the `host` and `mount` dimensions. `docker system prune`, `git worktree prune`, `pnpm store prune`, old `/data/projects` |
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

## Logs: `core-logs / core-log-app` (30 days)

The unified agent config `core-uac-app` (app only; the plugin is unsupported on the ops Micro) tails three sources:

| Source | File |
|---|---|
| Docker containers | `/data/docker/containers/*/*-json.log` (JSON; `time` parsed) |
| agent@* unit events | `/var/log/core/agent.log` (rsyslog rule `/etc/rsyslog.d/30-core-agent.conf`) |
| Bootstrap runs | `/var/log/core-bootstrap.log` |

- The agent flushes every 180 s. A new config can take up to about 10 minutes to reach the host.
- Search from the CLI:
  ```bash
  C=<core-compartment>; LG=$(make -s output-core ARGS='-raw log_group_id'); L=$(make -s output-core ARGS='-raw app_log_id')
  oci logging-search search-logs --search-query "search \"$C/$LG/$L\" | sort by datetime desc" \
    --time-start $(date -u -v-1H +%FT%TZ) --time-end $(date -u +%FT%TZ) --limit 20
  ```

## Uptime Kuma (https://status.mazuryktech.com)

- Login: user `admin`. Get the password with:
  ```bash
  oci secrets secret-bundle get-secret-bundle-by-name --vault-id $(make -s output-foundation ARGS='-raw vault_id') \
    --secret-name core-secret-uptime-kuma-admin --query 'data."secret-bundle-content".content' --raw-output | base64 -d
  ```
- **Known gap: Kuma data is on the ops boot volume and is not backed up.** After a wipe/restore or an ops rebuild, the login comes back (from Vault) but **monitors and history are gone**. Re-add the standard set:

  | Monitor | Type | Target |
  |---|---|---|
  | apex | HTTP(s) | `https://mazuryktech.com` (expect 200) |
  | each project | HTTP(s) | `https://<slug>[-<svc>].mazuryktech.com/health` |

  Notifications: add an SMTP notification using `core-secret-smtp` (587, STARTTLS, from `noreply@mazuryktech.com`).
- **Security:** Kuma is only ever published after its first-run setup is complete. See CLAUDE.md invariant 7. Never put another unauthenticated or first-run UI behind Caddy.

## Budget

`core-budget-monthly` is $1 per month on the whole tenancy. It alerts on ACTUAL spend at 50% and 100%, and on FORECAST at 100%.

Any alert means something non-free exists:
1. Run `make free-tier`.
2. Look at Billing, then Cost Analysis.
