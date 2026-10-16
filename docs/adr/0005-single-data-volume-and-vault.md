# 0005. A single `/data` volume plus Vault make wipe and restore possible

- Status: accepted
- Date: 2026-10-14

## Context

The compute layer should be rebuildable from code, so that drift, a bad bootstrap or a lost VM never needs manual repair. A rebuild must not lose the state an agent VM accumulates: the Claude login, git clones and worktrees, Docker images and the deployed projects. Secrets must not live on disk or in Terraform variables.

## Decision

- All mutable state of the app VM lives on one 100 GB block volume mounted at `/data`: the agent home, `/data/fleet` repos, the Docker data-root (overlay2, so layers survive), the edge compose files and certificates, deployed projects and Tailscale state.
- The volume is backed up daily by an incremental policy (keep 3). `make backup` takes a manual full backup, and `make wipe` always takes one before destroying the `core` layer.
- `make restore BACKUP=<ocid>` recreates the layer and creates the volume from the backup. `bootstrap.sh` is idempotent: it only runs `mkfs` when there is no filesystem, and it recreates the `agent` user with the existing uid/gid when `/data/home/agent` exists.
- Secrets live in Vault (`core-vault`, encrypted with `core-key-main`) and are read by instances through instance principals. The Vault is in the persistent foundation layer (ADR 0001).

## Consequences

- A wipe and restore drill was rehearsed end to end, and the findings were fixed in the repo.
- Anything stored on a boot volume is lost on rebuild. The one known case is Uptime Kuma history on the ops VM: bootstrap recreates its login, monitors and status page, but heartbeat history and hand-made monitors are gone.
- The boot and data volumes together have to stay within the Always-Free 200 GB (ADR 0002).
