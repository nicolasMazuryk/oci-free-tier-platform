# Access: SSH through core-bastion

- Both VMs are in `core-snet-priv` and have no public IP.
- Access goes through **OCI Bastion port-forwarding sessions**. These work without the Oracle Cloud Agent Bastion plugin.
- The key is the dedicated `~/.ssh/oci_core` (RSA 4096). The login user is `ubuntu`.

```bash
make ssh VM=app                      # interactive (real terminal)
make ssh VM=ops CMD='uptime'         # one-off command (works in the no-TTY ! shell too)
scripts/ssh.sh app sudo -iu agent    # same thing, direct
```

How it works (`scripts/bastion.sh`):
1. It looks up `core-bastion`, then reuses the cached session in `~/.cache/oci-core/session-<vm>` if it is ACTIVE with more than 10 minutes left. Otherwise it creates a 3-hour port-forwarding session to `10.0.2.10:22` or `10.0.2.20:22`.
2. It writes `~/.cache/oci-core/ssh_config-<vm>`, which has a `ProxyCommand ssh -W %h:%p <session>@host.bastion.uk-london-1.oci.oraclecloud.com`.
   Host keys go into `~/.ssh/known_hosts_oci_core`.
3. `make host-sync` uses the same config with rsync.

Firewalling:
- `core-nsg-app` and `core-nsg-ops` allow 22 only from the Bastion's private endpoint /32.
- Session clients are limited by `bastion_client_cidrs`. The default is `0.0.0.0/0`, and the key is still required.

## Common problems

| Symptom | Fix |
|---|---|
| `REMOTE HOST IDENTIFICATION HAS CHANGED` after a restore | `rm ~/.ssh/known_hosts_oci_core` (`make restore` already does this) |
| Hangs or `Connection closed` right after creating a session | The session can take about 30 s to become usable. Retry. Delete `~/.cache/oci-core/session-*` to force a new one. |
| `core-bastion not found` | The core layer isn't applied |
| Too many sessions | Each Bastion allows 20 active sessions. Old ones expire after 3 h. Delete with `oci bastion session delete --session-id ...` |
| Need a port other than 22 (e.g. Kuma UI directly) | `ssh -F ~/.cache/oci-core/ssh_config-ops -L 3001:127.0.0.1:3001 core-ops` |

## Agent / tmux access

```bash
make ssh VM=app
fleet ls
fleet attach <repo>        # Ctrl-b d to detach; do not Ctrl-c (that stops the server)
sudo -iu agent             # agent shell (passwordless sudo, docker)
```
