# Access: Tailscale (daily) and SSH through core-bastion (break-glass)

## Tailscale (daily)

`core-vm-cloud` is the tailnet node **`cloud`** (`tag:cloud`, MagicDNS `cloud.tailnet-example.ts.net`). Its OS hostname and VNIC
hostname label are `cloud` too. From the Mac or iPhone:

```bash
ssh agent@cloud           # Tailscale SSH: tailnet identity, no key (users agent, ubuntu)
mosh agent@cloud          # mosh over the tailnet (UDP 60000-61000 on tailscale0 only)
```

- Installed and joined by cloud bootstrap (`setup_tailscale`). The auth key comes from Vault `core-secret-tailscale-authkey`.
  It is only used when the node has no state. State lives on `/data/core/tailscale`.
- The tailnet policy is in claude-code-fleet (`config/tailscale/policy.hujson`), not here. It allows members → `cloud` and
  has **no** rule from `tag:cloud`, so the VM cannot reach the Mac or iPhone.
- On the VM: `tailscale status`, `sudo iptables -S INPUT | grep 60000`, `systemctl status tailscaled`.
- Claude Code on this VM (Agent View, Remote Control servers, settings) is documented in claude-code-fleet.

## Reverse tunnel (Mac → cloud, `core-sshd-tunnel`)

A dedicated OpenSSH sshd on `tailscale0:2222` carries the Mac's reverse tunnel (ADR 0008). User `rtunnel` may only open
the remote forward `127.0.0.1:22023`; no shell, no other forwards. A dead client is dropped after about 45–60 s, which
frees the listener.

Mac `~/.ssh/config`:

```
Host cloud-tunnel
  HostName cloud
  User rtunnel
  Port 2222
  IdentityFile ~/.ssh/id_ed25519_cloud_tunnel
  IdentitiesOnly yes
  ServerAliveInterval 15
  ServerAliveCountMax 3
```

- Keys: Vault `core-secret-tunnel-authorized-keys`, one public key per line
  (`make secret-put NAME=core-secret-tunnel-authorized-keys FILE=$HOME/.ssh/id_ed25519_cloud_tunnel.pub`, then
  `make host-sync VM=cloud`).
- Host key: `cloud`'s `/etc/ssh/ssh_host_ed25519_key.pub` (not the Tailscale SSH host key on port 22).
- On the VM: `systemctl status core-sshd-tunnel`, `journalctl -u core-sshd-tunnel`, `ss -ltnp | grep -E ':2222|:22023'`.

## Bastion (break-glass)

- Both VMs are in `core-snet-priv` and have no public IP.
- Access goes through **OCI Bastion port-forwarding sessions**. These work without the Oracle Cloud Agent Bastion plugin.
- The key is the dedicated `~/.ssh/oci_core` (RSA 4096). The login user is `ubuntu`.

```bash
make ssh VM=cloud                    # interactive (real terminal)
make ssh VM=ops CMD='uptime'         # one-off command (works in the no-TTY ! shell too)
scripts/ssh.sh cloud sudo -iu agent  # same thing, direct
```

How it works (`scripts/bastion.sh`):
1. It looks up `core-bastion`, then reuses the cached session in `~/.cache/oci-core/session-<vm>` if it is ACTIVE with more than 10 minutes left. Otherwise it creates a 3-hour port-forwarding session to `10.0.2.10:22` or `10.0.2.20:22`.
2. It writes `~/.cache/oci-core/ssh_config-<vm>`, which has a `ProxyCommand ssh -W %h:%p <session>@host.bastion.uk-london-1.oci.oraclecloud.com`.
   Host keys go into `~/.ssh/known_hosts_oci_core`.
3. `make host-sync` uses the same config with rsync.

Firewalling:
- `core-nsg-cloud` and `core-nsg-ops` allow 22 only from the Bastion's private endpoint /32.
- Session clients are limited by `bastion_client_cidrs`. The default is `0.0.0.0/0`, and the key is still required.

## Common problems

| Symptom | Fix |
|---|---|
| `REMOTE HOST IDENTIFICATION HAS CHANGED` after a restore | `rm ~/.ssh/known_hosts_oci_core` (`make restore` already does this) |
| Hangs or `Connection closed` right after creating a session | The session can take about 30 s to become usable. Retry. Delete `~/.cache/oci-core/session-*` to force a new one. |
| `core-bastion not found` | The core layer isn't applied |
| Too many sessions | Each Bastion allows 20 active sessions. Old ones expire after 3 h. Delete with `oci bastion session delete --session-id ...` |
| Need a port other than 22 (e.g. Kuma UI directly) | `ssh -F ~/.cache/oci-core/ssh_config-ops -L 3001:127.0.0.1:3001 core-ops` |

## Agent access

```bash
ssh agent@cloud            # daily (Tailscale); `make ssh VM=cloud` then `sudo -iu agent` as break-glass
```

Agent View, the Remote Control servers (`cc-rc@<repo>`) and `fleet` (on the Mac) are claude-code-fleet's: its
`docs/runbooks/` (`ac` attaches to Agent View in tmux session `fleet`; `fleet logs|restart cloud <repo>`).
