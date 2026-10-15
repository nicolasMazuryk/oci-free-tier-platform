# Agent fleet: repos and sessions

> **Moving to cc-orchestrator.** Claude Code on this VM is owned by
> [cc-orchestrator](https://github.com/nicolasMazuryk/cc-orchestrator) (`docs/runbooks/add-repo.md` there). Its Phase 4
> replaces `agent@<repo>` and `fleet` with `cc-rc@<repo>` and a Mac-side `fleet`. Until then, this page describes
> what runs today.

Each repo runs one Claude Code Remote Control server, `agent@<repo>` (systemd). It is a tmux session on socket `agent-<repo>`, running:

```
claude remote-control --spawn worktree --permission-mode auto --remote-control-session-name-prefix <repo>
```

Every session you start from the Claude app's Code tab, or from claude.ai/code, gets its own git worktree in `/data/fleet/<repo>`.

## One-time prerequisites (human, real terminal)

1. `core-secret-github-pat` is in Vault, and `make host-sync VM=app` has run since. Check with `sudo -iu agent gh auth status`. See [00-first-deploy §5](00-first-deploy.md).
2. `sudo -iu agent claude auth login` has been done.
   - This needs a full claude.ai login. API keys and `setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` do **not** work with Remote Control.
3. Push notifications are on in `/config`.

## Commands (on core-vm-app: `make ssh VM=app`)

| Action | Command |
|---|---|
| Add a repo | `fleet add <repo>` clones `https://github.com/nicolasMazuryk/<repo>.git` into `/data/fleet/<repo>` and enables `agent@<repo>` |
| First run only | `fleet attach <repo>`, accept the workspace trust (and Remote Control) prompt, then **Ctrl-b d** to detach |
| List | `fleet ls` |
| Logs | `fleet logs <repo>` (journal: start/stop/fail; also in `core-log-app`, source `/var/log/core/agent.log`) |
| Restart | `fleet restart <repo>` |
| Remove | `fleet rm <repo>` shows worktrees first. **Unpushed work is lost.** |
| Prune stale worktrees | `sudo -iu agent git -C /data/fleet/<repo> worktree prune` |

Only personal repos are reachable, by design. The fine-grained PAT has a single owner, and there are no SSH keys or classic PATs on the VM.

## Behaviour

- **Crash or network drop:** systemd restarts the server after 30 s (`Restart=always`). Restarting in the same directory brings its sessions back for about 4 hours.
- **Priority:** agents run with `CPUWeight=200`. That is a priority under contention, not a cap. Docker containers stay unlimited.
- **Capacity:** 2 OCPU / 12 GB fits 8–10 mostly idle sessions.
  - Concurrent `tsc`, tests or `next build` runs slow each other down.
  - The 16 GB swap absorbs memory spikes.
  - Watch `core-alarm-app-mem` and `core-alarm-app-cpu`.
- **Disk:** use pnpm. Its content-addressable store is at `/data/home/agent`, so N worktrees don't duplicate `node_modules`. Watch `core-alarm-app-disk`.
- **Permissions:**
  - `~/.claude/settings.json` has `"defaultMode": "auto"`.
  - The auto-mode classifier still blocks some high-risk actions, such as production deploys and fetching IMDS credentials. Approve those in the session, or add to `autoMode.environment`.
  - The `agent` user has passwordless sudo and is in the docker group.

## After a restore

Nothing to do. `/data/home/agent` (login, gh auth) and `/data/fleet` come back from the backup, and bootstrap re-enables `agent@<repo>` for every clone.
