# 0008. Reverse-tunnel endpoint: a dedicated OpenSSH sshd on tailscale0:2222

- Status: accepted
- Date: 2026-10-28

## Context

The Mac holds a persistent `ssh -N -R 127.0.0.1:22023:localhost:22` to `cloud` so agents on `cloud` can reach the Mac (phone-control-router; `cloud` never initiates a tailnet connection to the Mac). Tailscale SSH answers port 22 on the tailnet and has no server-side keepalive: when the Mac sleeps or its client dies without a clean close, the `-R` listener on `cloud` stays bound for an hour or more, the Mac's reconnect fails with `remote port forwarding failed for listen port 22023`, and only a `tailscaled` restart frees it.

## Decision

- **`core-sshd-tunnel`**, a second OpenSSH daemon (`/etc/ssh/sshd_config_tunnel`, systemd unit, host key shared with `ssh.service`), listens on port **2222**, reachable on **`tailscale0` only** (iptables INPUT accept on that interface; the VM has no public IP).
- **`ClientAliveInterval 15`, `ClientAliveCountMax 3`**: a dead client is dropped and its listener freed in about 45–60 s.
- **One user, one forward.** User `rtunnel`: system account, shell `nologin`, no password, `ForceCommand nologin`, public-key auth only, `PermitListen 127.0.0.1:22023`, `PermitOpen none`, no agent/X11/TTY/stream-local forwarding. Each authorized key also carries `restrict,port-forwarding,permitlisten="127.0.0.1:22023"`.
- **Keys come from Vault `core-secret-tunnel-authorized-keys`** (one public key per line). Without the secret the unit stays disabled; when Vault is unreachable the existing key file is kept.
- Tailscale SSH stays the daily login on port 22; it is not used for the tunnel. Tailscale SSH has no keepalive setting, and switching `ssh.service` to the tailnet would remove the tailnet-identity login.

## Consequences

- The Mac's tunnel job targets `rtunnel@cloud:2222` with its own key (`~/.ssh/id_ed25519_cloud_tunnel`), pinned to `cloud`'s OpenSSH host key (Tailscale SSH presents different host keys).
- A Mac sleep or crash costs at most about a minute of tunnel downtime after wake, with no manual step on `cloud`.
- A further forward port needs a change to `TUNNEL_LISTEN` in `host/cloud/bootstrap.sh`.
