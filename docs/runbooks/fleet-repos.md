# Agent fleet: repos and sessions → claude-code-fleet

**Claude Code on `core-vm-cloud` is owned by [claude-code-fleet](https://github.com/nicolasMazuryk/claude-code-fleet)**
(`~/Documents/claude-code-fleet`, ADR 0002). This repo no longer installs Claude Code, `agent@<repo>` or `fleet`.

| What | Where (claude-code-fleet) |
|---|---|
| Install / rebuild Claude Code on cloud (binary, settings, units) | `./install.sh cloud` from the Mac; `docs/runbooks/cloud-rebuild.md` |
| Repos with a Remote Control server (`cloud/<repo>` in the Claude app) | `config/cloud/repos.txt`; units `cc-rc@<repo>` |
| Add / remove a repo | `docs/runbooks/add-repo.md`, `remove-repo.md` (`repo-init`) |
| Agent View | `cc-agents.service`, tmux session `fleet` (`ac` from the Mac) |
| List / logs / restart | `fleet`, `fleet logs cloud <repo>`, `fleet restart cloud <repo>` (on the Mac) |
| Upgrade Claude Code | `docs/runbooks/upgrade-claude-code.md` |

What this repo still provides for the fleet (bootstrap): `/data/fleet` and `/data/home/agent` on the persistent
volume, the `agent` user (passwordless sudo, docker group, linger), Node 24 + pnpm, git identity, gh auth from
`core-secret-github-pat`, Tailscale node `cloud`, mosh on `tailscale0`, and shipping of `/var/log/core/agent.log` to
`core-log-cloud`.

Old command → new:

| oci `fleet` (removed) | claude-code-fleet |
|---|---|
| `fleet add <repo>` | add to `config/cloud/repos.txt`, `./install.sh cloud` (clones it), then trust once: `ssh -t cloud 'repo-init <repo>'` |
| `fleet attach <repo>` | `ac` (Agent View); Remote Control servers run headless under systemd |
| `fleet ls` / `logs` / `restart` | `fleet` / `fleet logs cloud <repo>` / `fleet restart cloud <repo>` on the Mac |
| `fleet rm <repo>` | claude-code-fleet `docs/runbooks/remove-repo.md` |

`make host-sync VM=cloud` removes any leftover `agent@*` units, `agent@.service`, `/usr/local/bin/fleet` and their
tmux servers (bootstrap step 5), and never touches `cc-*` units.

## Capacity notes (machine side)

- 2 OCPU / 12 GB fits 8–10 mostly idle sessions; the 16 GB swap absorbs spikes. Watch `core-alarm-cloud-mem`/`-cpu`.
- Disk: use pnpm (store under `/data/home/agent`, shared by worktrees). Watch `core-alarm-cloud-disk`.
- Only personal repos are reachable: the fine-grained PAT has a single owner; no SSH keys or classic PATs on the VM.
