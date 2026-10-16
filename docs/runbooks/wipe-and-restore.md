# Wipe and restore the core layer

The core layer (network, NLB, Bastion, VMs, volume, alarms, logs) can be destroyed and rebuilt.

**These stay untouched:** foundation (Vault, state, reserved IP 203.0.113.10, email, budget) and cloudflare (DNS, Origin cert). So DNS never changes.

> Agents: **never run `make wipe` without the human's explicit go-ahead.**

## What survives

| Survives (`/data` restored from backup) | Lost (re-created by bootstrap) | Lost for good |
|---|---|---|
| agent home: Claude login, `~/.claude`, gh auth, pnpm store; `/data/fleet` clones + worktrees; Docker images/volumes/containers in `/data/docker`; `/data/projects` | OS packages, swap, users, systemd units, Caddy cert files; **Uptime Kuma admin login, `core-email` notification, standard monitors, public status page `core` + entry page** (all from code/Vault) | **Uptime Kuma heartbeat history** and any monitors added by hand in the UI (Kuma data is on the unbacked ops boot volume). Also lost: log/metric history before the wipe (it stays in OCI, attached to the old OCIDs), and anything written outside `/data` on cloud. |

## Wipe

```bash
make wipe            # asks you to type 'wipe'; in scripts: CONFIRM=wipe make wipe
```

1. `scripts/backup-now.sh` makes a **FULL** manual backup `core-bkp-manual-prewipe-<ts>` of `core-bv-cloud-data` and waits until it is AVAILABLE.
   - It refuses if 5 backups already exist (the free-tier cap). Delete an old manual one first:
     `oci bv backup list --compartment-id <core>`, then `oci bv backup delete --volume-backup-id ...`.
   - For consistency, stop heavy writers first. For example, stop the Claude Code units with `sudo systemctl stop 'cc-rc@*' cc-agents`, and run `docker compose stop` for databases.
2. The backup OCID is saved to `.last-wipe-backup` (gitignored). Keep a note of it anyway.
3. `terraform destroy` runs on `terraform/core`. The reserved IP detaches from the NLB and stays.

Use `SKIP_BACKUP=1` only if you already have a fresh backup.

## Restore

```bash
make restore BACKUP=ocid1.volumebackup.oc1....   # /data from that backup
make restore                                     # uses .last-wipe-backup if present
make restore BACKUP=none                         # fresh, empty /data
```

What happens:
- `terraform apply` runs with `-var data_volume_backup_id=<ocid>`. The new `core-bv-cloud-data` is created from the backup.
  `ignore_changes = [source_details]` means later plans without the var stay clean.
- Cached Bastion sessions and `~/.ssh/known_hosts_oci_core` are cleared, because the new VMs have new host keys.
- On first boot, cloud bootstrap sees the existing ext4 `data` filesystem and **does not mkfs it**. It recreates `agent` with the original uid/gid and brings Caddy up. The Claude Code units (`cc-rc@<repo>`, `cc-agents`) are under `/etc` on the boot volume, so they come back from cc-orchestrator: run `./install.sh cloud` from the Mac (step below).
- Tailscale: the node state is on `/data/core/tailscale`, so a restore from backup rejoins as the same node `cloud`
  (same 100.x IP, no auth key needed). With `BACKUP=none` there is no state: **first delete the old `cloud` machine in
  the Tailscale admin console** (or the new node becomes `cloud-1`), and make sure `core-secret-tailscale-authkey` holds
  a valid (unexpired) key.
- Containers with `restart: unless-stopped` come back with Docker.
- ops bootstrap creates a fresh Kuma bound to localhost. It sets Kuma up from Vault, provisions the notification, monitors and status page `core`, and only then publishes it.

## Verify after restore

```bash
make plan-all
make free-tier
curl -sI https://mazuryktech.com | head -1
curl -sI https://status.mazuryktech.com | grep -i location   # -> /status/core, never /setup*
curl -s https://status.mazuryktech.com/api/status-page/heartbeat/core | jq '.heartbeatList|map_values(.[-1].status)'   # 1 = UP
make ssh VM=cloud CMD='df -h /data; sudo -iu agent gh auth status; sudo -iu agent .local/bin/claude auth status; sudo docker ps'
# then Claude Code, from the Mac: cd ~/Documents/cc-orchestrator && ./install.sh cloud   (cc-orchestrator docs/runbooks/cloud-rebuild.md)
ssh cloud 'systemctl list-units "cc-rc@*" cc-agents --no-legend'
ssh agent@cloud 'tailscale status --self --peers=false'   # from the Mac: rejoined as cloud
```

Then:
- In the Claude app, check that the repo's Remote Control session is listed and that a new session creates a worktree.
- Re-add any Kuma monitors that were added by hand in the UI. The standard set is recreated automatically.

## Real timings (drill, 2026-10-13)

| Step | Time |
|---|---|
| `make wipe`: FULL backup of 100 GB volume (~370 MB used) until AVAILABLE, then destroy of 69 resources | 3 m 37 s (20:34:37 to 20:38:14) |
| `make restore`: apply of 69 resources (A1 capacity was available) | 1 m 27 s (20:38:35 to 20:40:02) |
| cloud bootstrap on first boot (volume attach, swap, OCI CLI, Node, Docker, agent user, gh, Caddy) | about 3 min |
| ops bootstrap (E2.1.Micro is slow: Docker install + Kuma image pull + first-run setup + provisioning) | about 14 min (20:40 to 20:54) |
| Apex downtime (last 200 to first 200) | 14 m 51 s (20:36:52 to 20:51:43); this included about 9 min lost to the Docker image-store bug below. Expect **about 6 min** |
| status.mazuryktech.com downtime | until 20:55:09, about 18.5 min, because it waits on the slow ops VM. It returned 502 while Kuma was localhost-only, and **never** showed `/setup` |

The drill verified all of this with no manual steps:
- the marker file and the `/data` listing hash matched
- the agent's Claude login (`loggedIn: true`) and gh auth survived
- `agent@offers-pipeline` came back **Connected** with the same Remote Control environment id and its session, and no trust prompt
- Kuma's monitors and status page were recreated and UP
- `make ssh` worked with the new host keys

Two bugs were found and fixed during the drill:
1. **Docker 29 containerd image store.** By default, image layers and container snapshots live in `/var/lib/containerd` on the *boot* volume, so the restored `/data/docker` had container metadata without layers. Caddy failed with `RWLayer of container ... is unexpectedly nil`.
   - **Fix:** app's `daemon.json` now sets `"features": {"containerd-snapshotter": false}`, so everything (overlay2) is under `/data/docker` and is backed up.
   - **Fix:** bootstrap also recreates `core-edge` if it fails to start.
2. **`core-alarm-metrics-absent`** fired after the restore, because the destroyed instances' metric streams (old `resourceId`) stayed absent. It is now grouped by the stable `host` dimension (`.groupBy(host).absent()`).

`make wipe` now stops the Claude Code units on cloud (`cc-rc@*`, `cc-agents`; `agent@*` at the time of the drill) before the backup, which gives a clean backup. Live Remote Control sessions resume after the restore.

## Clean up backups

After a successful restore, delete old manual backups so you stay within 5 in total (3 come from the daily policy):
`oci bv backup list --compartment-id $(make -s output-foundation ARGS='-raw core_compartment_id') --query 'data[].{n:"display-name",id:id,t:"time-created"}' --output table`
