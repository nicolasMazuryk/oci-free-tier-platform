# 0009. Retire the phone-control-router reverse tunnel endpoint

- Status: accepted
- Supersedes: [ADR 0008](0008-reverse-tunnel-sshd.md)
- Date: 2026-11-02

## Context

phone-control-router (2.0.0) drives the iPhone from the MacBook only. It has no `phone` client on `cloud`, no SSH forced command and no Mac-opened reverse tunnel, and agents on `cloud` do not use the iPhone. The only consumer of the ADR 0008 endpoint (`core-sshd-tunnel`, user `rtunnel`, TCP 2222 on `tailscale0`, remote forward `127.0.0.1:22023`) is gone, while the endpoint itself is a second sshd, a system user, a firewall opening and a Vault secret to keep patched and audited.

## Decision

- **`cloud` runs no reverse-tunnel endpoint.** Tailnet SSH into `cloud` is Tailscale SSH on port 22 only; nothing on `cloud` reaches the Mac (no rule with `src: tag:cloud`, unchanged).
- **Bootstrap tears the endpoint down idempotently.** `host/cloud/bootstrap.sh` section 4c (`remove_tunnel_sshd`) stops and disables `core-sshd-tunnel.service`, removes `/etc/systemd/system/core-sshd-tunnel.service`, `/etc/ssh/sshd_config_tunnel`, `/etc/ssh/tunnel_authorized_keys` and `/run/sshd-tunnel.pid`, deletes user `rtunnel`, and removes the `-i tailscale0 -p tcp --dport 2222` INPUT accept, live and from `/etc/iptables/rules.v4` (`revoke_tcp_on_iface` in `host/common/lib.sh`). On a clean host it does nothing. It never touches `ssh.service`, its host keys or Tailscale SSH.
- **The Vault secret `core-secret-tunnel-authorized-keys` is deleted** by the owner (scheduled deletion); bootstrap no longer reads it.
- Keeping the endpoint stopped but installed is not used: an unused sshd, user and firewall rule still widen the attack surface and need upkeep, and a reinstated tunnel would need a fresh design for whatever uses it.

## Consequences

- One sshd on `cloud` (`ssh.service`, reached through Bastion) plus Tailscale SSH; no listener on 2222 or 22023.
- The next `make host-sync VM=cloud` (or a fresh first boot) converges an already-provisioned VM; the manual steps below do the same without a full bootstrap run.
- The Mac keeps no tunnel job: no `Host cloud-tunnel` stanza in `~/.ssh/config` and no `~/.ssh/id_ed25519_cloud_tunnel` key pair are needed.
- A future Mac ↔ `cloud` channel needs a new ADR.

## Manual teardown on the live VM

Run by the owner, not by agents.

1. On the Mac, open a shell on `cloud` (Tailscale SSH):

   ```bash
   ssh ubuntu@cloud
   ```

2. On `cloud`, remove the endpoint (each step is a no-op when already done):

   ```bash
   sudo systemctl disable --now core-sshd-tunnel.service 2>/dev/null; true
   sudo rm -f /etc/systemd/system/core-sshd-tunnel.service /etc/ssh/sshd_config_tunnel /etc/ssh/tunnel_authorized_keys /run/sshd-tunnel.pid
   sudo systemctl daemon-reload
   id rtunnel >/dev/null 2>&1 && sudo userdel rtunnel; true
   while sudo iptables -C INPUT -i tailscale0 -p tcp -m tcp --dport 2222 -j ACCEPT 2>/dev/null; do sudo iptables -D INPUT -i tailscale0 -p tcp -m tcp --dport 2222 -j ACCEPT; done
   sudo sed -i '\|^-A INPUT -i tailscale0 -p tcp -m tcp --dport 2222 -j ACCEPT$|d' /etc/iptables/rules.v4
   ```

3. On `cloud`, verify. Expected: `0`, `0`, `inactive`, `id: 'rtunnel': no such user`:

   ```bash
   ss -ltn | grep -cE ':2222|:22023'
   sudo iptables -S INPUT | grep -c 'dport 2222'
   systemctl is-active core-sshd-tunnel.service
   id rtunnel
   ```

4. On the Mac, in `~/code/oci-free-tier-platform`, schedule deletion of the Vault secret (OCI keeps it for the pending-deletion window, 30 days by default):

   ```bash
   cd ~/code/oci-free-tier-platform
   tenancy=$(bash -c 'source scripts/lib.sh && oci_cfg tenancy')
   core=$(oci iam compartment list --compartment-id "$tenancy" --name core --lifecycle-state ACTIVE --query 'data[0].id' --raw-output)
   sid=$(oci vault secret list --compartment-id "$core" --name core-secret-tunnel-authorized-keys --all --query 'data[0].id' --raw-output)
   oci vault secret schedule-secret-deletion --secret-id "$sid"
   ```

5. On the Mac, remove the tunnel's SSH client leftovers: delete the `Host cloud-tunnel` block from `~/.ssh/config`, then:

   ```bash
   trash ~/.ssh/id_ed25519_cloud_tunnel ~/.ssh/id_ed25519_cloud_tunnel.pub
   ```
