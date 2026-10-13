# Wipe and restore the core layer

The core layer (network, NLB, Bastion, VMs, volume, alarms, logs) can be destroyed and rebuilt.

**These stay untouched:** foundation (Vault, state, reserved IP 203.0.113.10, email, budget) and cloudflare (DNS, Origin cert). So DNS never changes.

> Agents: **never run `make wipe` without the human's explicit go-ahead.**

## What survives

| Survives (`/data` restored from backup) | Lost (re-created by bootstrap) | Lost for good |
|---|---|---|
| agent home: Claude login, `~/.claude`, gh auth, pnpm store; `/data/fleet` clones + worktrees; Docker images/volumes/containers in `/data/docker`; `/data/projects` | OS packages, swap, users, systemd units, Caddy cert files (all reinstalled from code/Vault) | **Uptime Kuma data on the ops boot volume: monitors and history.** The admin login comes back from Vault. Also lost: log/metric history before the wipe (it stays in OCI, attached to the old OCIDs), and anything written outside `/data` on app. |

## Wipe

```bash
make wipe            # asks you to type 'wipe'; in scripts: CONFIRM=wipe make wipe
```

1. `scripts/backup-now.sh` makes a **FULL** manual backup `core-bkp-manual-prewipe-<ts>` of `core-bv-app-data` and waits until it is AVAILABLE.
   - It refuses if 5 backups already exist (the free-tier cap). Delete an old manual one first:
     `oci bv backup list --compartment-id <core>`, then `oci bv backup delete --volume-backup-id ...`.
   - For consistency, stop heavy writers first. For example, stop every agent with `sudo systemctl stop 'agent@*'`, and run `docker compose stop` for databases.
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
- `terraform apply` runs with `-var data_volume_backup_id=<ocid>`. The new `core-bv-app-data` is created from the backup.
  `ignore_changes = [source_details]` means later plans without the var stay clean.
- Cached Bastion sessions and `~/.ssh/known_hosts_oci_core` are cleared, because the new VMs have new host keys.
- On first boot, app bootstrap sees the existing ext4 `data` filesystem and **does not mkfs it**. It recreates `agent` with the original uid/gid, re-enables `agent@<repo>` for every clone, and brings Caddy up.
- Containers with `restart: unless-stopped` come back with Docker.
- ops bootstrap creates a fresh Kuma, set up from Vault before it is exposed.

## Verify after restore

```bash
make plan-all
make free-tier
curl -sI https://mazuryktech.com | head -1
curl -sI https://status.mazuryktech.com | head -3     # -> /dashboard, never /setup*
make ssh VM=app CMD='df -h /data; fleet ls; sudo -iu agent gh auth status; sudo -iu agent claude auth status; sudo docker ps'
```

Then:
- In the Claude app, check that the repo's Remote Control session is listed and that a new session creates a worktree.
- Recreate the Uptime Kuma monitors (see [monitoring-alerts](monitoring-alerts.md)).

## Clean up backups

After a successful restore, delete old manual backups so you stay within 5 in total (3 come from the daily policy):
`oci bv backup list --compartment-id $(make -s output-foundation ARGS='-raw core_compartment_id') --query 'data[].{n:"display-name",id:id,t:"time-created"}' --output table`
