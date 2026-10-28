#!/usr/bin/env bash
# core-vm-cloud bootstrap. Idempotent: safe to re-run (cloud-init first boot,
# `make host-sync VM=cloud`, or after a restore from backup).
source /opt/core/lib.sh
exec > >(tee -a /var/log/core-bootstrap.log) 2>&1
log "=== cloud bootstrap start"
export DEBIAN_FRONTEND=noninteractive
DATA_DEV=/dev/oracleoci/oraclevdb
migrate_core_env

# ---- 0. OS hostname `cloud` ---------------------------------------------------
# Same name as the Tailscale node; Claude Code shows the OS hostname as the Remote Control device name.
# cloud-init re-applies a hostname on every boot (preserve_hostname: false, and Oracle's drop-in sets
# manage_etc_hosts: localhost), taken from IMDS unless the config names one. Pin it, so a reboot keeps
# `cloud` whatever the VNIC hostname_label says. The 99-zz- prefix sorts after 99-oracle-*.
OS_HOSTNAME=cloud
set_os_hostname() {
  local cfg=/etc/cloud/cloud.cfg.d/99-zz-core-hostname.cfg want
  want="# managed by /opt/core/bootstrap.sh (oci-infra host/cloud)
preserve_hostname: false
hostname: $OS_HOSTNAME
fqdn: $OS_HOSTNAME
manage_etc_hosts: localhost"
  if [[ "$(cat "$cfg" 2>/dev/null)" != "$want" ]]; then
    printf '%s\n' "$want" > "$cfg" || return 1
    log "cloud-init hostname drop-in written: $cfg"
  fi
  # /etc/hosts first, so sudo can resolve the new name the moment it is set
  if ! grep -qE "^127\.0\.1\.1[[:space:]]+$OS_HOSTNAME([[:space:]]+$OS_HOSTNAME)?[[:space:]]*$" /etc/hosts; then
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
      sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $OS_HOSTNAME $OS_HOSTNAME/" /etc/hosts || return 1
    else
      echo "127.0.1.1 $OS_HOSTNAME $OS_HOSTNAME" >> /etc/hosts || return 1
    fi
    log "/etc/hosts: 127.0.1.1 -> $OS_HOSTNAME"
  fi
  if [[ "$(hostnamectl --static 2>/dev/null)" != "$OS_HOSTNAME" || "$(hostname)" != "$OS_HOSTNAME" ]]; then
    hostnamectl set-hostname "$OS_HOSTNAME" || return 1
    log "OS hostname set to $OS_HOSTNAME (running Remote Control servers keep their old device name until restarted)"
  fi
}
set_os_hostname || log "WARN: could not set the OS hostname to $OS_HOSTNAME"

# ---- 1. data volume (/data) -------------------------------------------------
for i in $(seq 1 120); do [[ -b $DATA_DEV ]] && break; log "waiting for $DATA_DEV ($i)"; sleep 5; done
[[ -b $DATA_DEV ]] || { log "FATAL: $DATA_DEV not attached"; exit 1; }
dev="$(readlink -f "$DATA_DEV")"
fstype="$(blkid -o value -s TYPE "$dev" || true)"
if [[ -z "$fstype" ]]; then
  log "no filesystem on $dev: mkfs.ext4 -L data (first deploy)"
  mkfs.ext4 -q -L data "$dev"
else
  log "existing $fstype filesystem on $dev (label: $(blkid -o value -s LABEL "$dev" || true)): keeping it"
  [[ "$(blkid -o value -s LABEL "$dev" || true)" == data ]] || e2label "$dev" data
fi
mkdir -p /data
grep -q '^LABEL=data ' /etc/fstab || echo 'LABEL=data /data ext4 defaults,nofail 0 2' >> /etc/fstab
mountpoint -q /data || mount /data
# A restored volume may be larger than the original: grow the fs to fit.
resize2fs "$dev" >/dev/null 2>&1 || true

# ---- 2. swap + base packages ------------------------------------------------
ensure_swap 16G
apt-get update -qq
apt-get install -y -qq git tmux gh jq build-essential rsync unzip ca-certificates curl mosh >/dev/null
install_oci_cli

# Node LTS (system-wide) + pnpm via corepack
if ! command -v node >/dev/null || [[ "$(node -v | cut -d. -f1)" != "v${NODE_MAJOR:-24}" ]]; then
  log "installing Node ${NODE_MAJOR:-24}.x"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR:-24}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
corepack enable 2>/dev/null || npm install -g pnpm >/dev/null

# ---- 3. Docker (data-root on /data) ----------------------------------------
install_docker /data/docker classic
mkdir -p /data/core/edge/certs /data/projects /data/fleet

# ---- 4. agent user ------------------------------------------------------------
if ! id agent >/dev/null 2>&1; then
  if [[ -d /data/home/agent ]]; then
    # restore: home already on the volume; reuse its uid/gid
    uid="$(stat -c %u /data/home/agent)"; gid="$(stat -c %g /data/home/agent)"
    getent group "$gid" >/dev/null || groupadd -g "$gid" agent
    useradd -u "$uid" -g "$gid" -M -d /data/home/agent -s /bin/bash -G docker agent
    log "re-created agent user (uid $uid) over existing /data/home/agent"
  else
    mkdir -p /data/home
    useradd -m -d /data/home/agent -s /bin/bash -G docker agent
    log "created agent user"
  fi
fi
usermod -aG docker agent
echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent && chmod 440 /etc/sudoers.d/agent
chown agent:agent /data/fleet /data/projects
loginctl enable-linger agent >/dev/null 2>&1 || true

as_agent() { sudo -iu agent bash -lc "$1"; }
# Claude Code itself (binary, settings, PATH, units) is installed by claude-code-fleet `./install.sh cloud`, not here.
as_agent "git config --global user.name '${GIT_USER_NAME}' && git config --global user.email '${GIT_USER_EMAIL}' && git config --global init.defaultBranch main"

# GitHub: fine-grained PAT from Vault, HTTPS only (skipped until the secret exists)
if pat="$(secret_get core-secret-github-pat)"; then
  printf '%s' "$pat" | sudo -iu agent gh auth login --hostname github.com --with-token \
    && as_agent 'gh auth setup-git && gh config set git_protocol https' \
    && log "gh authenticated for agent" || log "WARN: gh auth failed"
  unset pat
else
  log "core-secret-github-pat not in Vault yet: skipping gh auth (Phase 6 hand-off)"
fi

# ---- 4b. tailnet access: Tailscale node `cloud` (tag:cloud) + mosh ------------
# Daily access from the Mac / iPhone is Tailscale SSH and mosh (claude-code-fleet ADR 0001); Bastion stays
# as break-glass. Tailscale is outbound-only: no public IP, no new ingress. Node state lives on /data, so a
# restore from backup rejoins as the same node (same name and 100.x IP). Never fatal: a tailnet problem
# must not stop the rest of the bootstrap.
# `cloud` also advertises itself as an exit node (browser-router egress); a tailnet autoApprover admits it, and
# tailscaled's own ts-forward chain handles FORWARD, so no extra iptables rule is needed. `cloud` never uses an
# exit node itself (ADR 0007).
TS_HOSTNAME=cloud TS_TAGS=tag:cloud TS_STATE=/data/core/tailscale
setup_tailscale() {
  local dropin=/etc/systemd/system/tailscaled.service.d/10-core-state.conf want changed=0 state="" kf rc codename
  mkdir -p "$TS_STATE" "${dropin%/*}" && chmod 700 "$TS_STATE" || return 1
  want="[Unit]
RequiresMountsFor=/data

[Service]
ExecStart=
ExecStart=/usr/sbin/tailscaled --state=$TS_STATE/tailscaled.state --statedir=$TS_STATE --socket=/run/tailscale/tailscaled.sock --port=\${PORT} \$FLAGS"
  if [[ "$(cat "$dropin" 2>/dev/null)" != "$want" ]]; then
    printf '%s\n' "$want" > "$dropin" && systemctl daemon-reload || return 1
    changed=1
  fi
  if ! command -v tailscale >/dev/null; then
    log "installing Tailscale"
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
      && curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list \
      && apt-get update -qq && apt-get install -y -qq tailscale >/dev/null || return 1
    changed=0 # first start already used the drop-in
  fi
  systemctl enable --quiet --now tailscaled || return 1
  if (( changed )); then log "tailscaled state dir changed: restarting"; systemctl restart tailscaled || return 1; fi
  for _ in $(seq 1 15); do
    state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')" || state=""
    [[ -n $state && $state != NoState ]] && break; sleep 1
  done
  case "$state" in
    Running) # already joined: keep the settings converged, never re-auth. `set` keeps flags it is not given, so
      # --advertise-routes= drops any route other than the exit node's (e.g. /32s left by a former app connector).
      tailscale set --ssh --hostname="$TS_HOSTNAME" --accept-dns=false --advertise-routes= --advertise-exit-node || return 1
      log "tailscale up as $(tailscale status --json | jq -r '.Self.DNSName')" ;;
    Stopped) # logged in, but `tailscale down` was run
      tailscale up --ssh --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAGS" --accept-dns=false --advertise-exit-node --timeout=60s || return 1
      log "tailscale brought back up" ;;
    *) # NeedsLogin / fresh node: join with the reusable, tag:cloud auth key from Vault (never on argv)
      kf="$(mktemp)"; chmod 600 "$kf"
      if secret_get core-secret-tailscale-authkey > "$kf"; then
        rc=0
        tailscale up --ssh --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAGS" --accept-dns=false --advertise-exit-node \
          --auth-key="file:$kf" --timeout=60s || rc=$?
        rm -f "$kf"
        (( rc == 0 )) || return 1
        log "tailscale joined as $(tailscale status --json | jq -r '.Self.DNSName')"
      else
        rm -f "$kf"
        log "core-secret-tailscale-authkey not in Vault yet: skipping tailscale up (state: ${state:-unknown})"
      fi ;;
  esac
}
enable_ip_forward || log "WARN: ip_forward sysctls failed (exit node will not forward)"
setup_tailscale || log "WARN: Tailscale setup failed (Bastion still works; fix, then make host-sync VM=cloud)"
# mosh over the tailnet only (UDP 60000-61000 on tailscale0), before the image's REJECT, persisted
allow_udp_on_iface tailscale0 60000:61000

# ---- 4c. reverse-tunnel endpoint: OpenSSH on tailscale0:2222, user `rtunnel` ------------
# The Mac opens `ssh -N -R 127.0.0.1:22023:localhost:22` to this endpoint (phone-control-router), so cloud agents
# reach the Mac's sshd. A Tailscale SSH session keeps a dead client's -R listener after the Mac sleeps; this sshd
# probes the client (ClientAlive 15 s x 3) and frees the listener within ~45 s. Scope: tailnet only (TCP 2222 on
# tailscale0; the VM has no public IP), user `rtunnel` (no shell, no password), public key only, one remote
# forward to TUNNEL_LISTEN and nothing else. Keys: Vault `core-secret-tunnel-authorized-keys` (one public key per
# line; restrictions are added here). Without the secret the unit stays stopped.
TUNNEL_USER=rtunnel TUNNEL_PORT=2222 TUNNEL_LISTEN=127.0.0.1:22023
setup_tunnel_sshd() {
  local cfg=/etc/ssh/sshd_config_tunnel keys=/etc/ssh/tunnel_authorized_keys unit=/etc/systemd/system/core-sshd-tunnel.service
  local want tmp changed=0
  id "$TUNNEL_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$TUNNEL_USER" || return 1
  usermod -p '*' "$TUNNEL_USER" || return 1   # no password; not '!' (sshd without PAM refuses '!'-locked accounts)
  want="# Managed by oci-free-tier-platform host/cloud/bootstrap.sh (4c). Do not edit.
Port $TUNNEL_PORT
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /run/sshd-tunnel.pid
AllowUsers $TUNNEL_USER
AuthorizedKeysFile $keys
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM no
AllowTcpForwarding remote
PermitListen $TUNNEL_LISTEN
PermitOpen none
GatewayPorts no
AllowStreamLocalForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PermitTTY no
PermitUserRC no
PermitUserEnvironment no
ForceCommand /usr/sbin/nologin
ClientAliveInterval 15
ClientAliveCountMax 3
MaxSessions 1
MaxAuthTries 2
LoginGraceTime 20
LogLevel VERBOSE"
  if [[ "$(cat "$cfg" 2>/dev/null)" != "$want" ]]; then printf '%s\n' "$want" > "$cfg"; chmod 644 "$cfg"; changed=1; fi
  tmp="$(mktemp)"
  if secret_get core-secret-tunnel-authorized-keys > "$tmp.raw"; then
    # only well-formed public keys, each pinned to the one forward
    grep -E '^(ssh-ed25519|ecdsa-sha2-nistp[0-9]+|ssh-rsa) [A-Za-z0-9+/=]+( .*)?$' "$tmp.raw" \
      | sed "s|^|restrict,port-forwarding,permitlisten=\"$TUNNEL_LISTEN\" |" > "$tmp"
  elif [[ -f $keys ]]; then cp "$keys" "$tmp"
  fi
  rm -f "$tmp.raw"
  if [[ -s $tmp ]] && ! cmp -s "$tmp" "$keys"; then install -m 644 -o root -g root "$tmp" "$keys"; changed=1; fi
  rm -f "$tmp"
  want="[Unit]
Description=OpenSSH reverse-tunnel endpoint (tailscale0:$TUNNEL_PORT, user $TUNNEL_USER)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
ExecStartPre=/usr/sbin/sshd -t -f $cfg
ExecStart=/usr/sbin/sshd -D -e -f $cfg
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes

[Install]
WantedBy=multi-user.target"
  if [[ "$(cat "$unit" 2>/dev/null)" != "$want" ]]; then printf '%s\n' "$want" > "$unit"; systemctl daemon-reload; changed=1; fi
  allow_tcp_on_iface tailscale0 "$TUNNEL_PORT"
  if [[ ! -s $keys ]]; then
    log "core-secret-tunnel-authorized-keys not in Vault yet: core-sshd-tunnel stays stopped"
    systemctl disable --quiet --now core-sshd-tunnel 2>/dev/null || true; return 0
  fi
  /usr/sbin/sshd -t -f "$cfg" || return 1
  systemctl enable --quiet core-sshd-tunnel || return 1
  # a restart drops live tunnels; only on a change (a HUP would keep them, but the unit may not be running yet)
  if (( changed )) || ! systemctl is-active --quiet core-sshd-tunnel; then
    systemctl restart core-sshd-tunnel || return 1; log "core-sshd-tunnel (re)started"
  fi
}
setup_tunnel_sshd || log "WARN: reverse-tunnel sshd setup failed (the Mac's tunnel cannot connect; fix, then make host-sync VM=cloud)"

# ---- 5. Claude Code: owned by claude-code-fleet ---------------------------------
# claude-code-fleet (github.com/nicolasMazuryk/claude-code-fleet, ADR 0002) installs the Claude Code binary, settings,
# Agent View (cc-agents.service) and the Remote Control units (cc-rc@<repo>.service) with `./install.sh cloud`.
# This bootstrap never touches cc-* units. It only removes what older versions of it installed (idempotent; a
# no-op once clean). Stopping agent@<repo> first keeps one Remote Control server per folder.
remove_legacy_claude_code() {
  local u s changed=0
  for u in $( { systemctl list-units 'agent@*' --all --plain --no-legend; systemctl list-unit-files 'agent@*' --no-legend; } \
              | awk '$1 ~ /^agent@.+\.service$/ {print $1}' | sort -u); do
    systemctl disable --now "$u" >/dev/null 2>&1 && log "legacy: stopped and disabled $u"
  done
  for s in /tmp/tmux-"$(id -u agent 2>/dev/null || echo none)"/agent-*; do
    [[ -S $s ]] || continue
    sudo -u agent tmux -S "$s" kill-server 2>/dev/null; rm -f "$s"; log "legacy: removed tmux server $s"
  done
  for f in /etc/systemd/system/agent@.service /usr/local/bin/fleet /opt/core/agent@.service /opt/core/fleet \
           /etc/rsyslog.d/30-core-agent.conf; do
    [[ -e $f ]] || continue
    rm -f "$f" && log "legacy: removed $f" && changed=1
  done
  (( changed )) && systemctl daemon-reload
  return 0
}
remove_legacy_claude_code || log "WARN: legacy Claude Code cleanup failed"

# ---- 6. edge (Caddy) with Cloudflare Origin cert -----------------------------
open_port 443
install -m 0644 /opt/core/edge/compose.yaml /data/core/edge/compose.yaml
sed -e "s/__DOMAIN__/${DOMAIN}/g" -e "s/__OPS_IP__/${OPS_IP}/g" /opt/core/edge/Caddyfile.tmpl > /data/core/edge/Caddyfile
umask 077
if secret_get core-secret-cf-origin-cert > /data/core/edge/certs/origin.pem.new \
   && secret_get core-secret-cf-origin-key > /data/core/edge/certs/origin.key.new; then
  mv /data/core/edge/certs/origin.pem.new /data/core/edge/certs/origin.pem
  mv /data/core/edge/certs/origin.key.new /data/core/edge/certs/origin.key
  chmod 600 /data/core/edge/certs/origin.*
  log "origin cert installed from Vault"
else
  rm -f /data/core/edge/certs/*.new
  log "WARN: could not read origin cert from Vault (keeping existing files if any)"
fi
umask 022
# --force-recreate is not used: a healthy edge keeps running. If a container's
# layer is missing (e.g. data restored from an image-store mismatch), recreate it.
if ! docker compose -f /data/core/edge/compose.yaml up -d --remove-orphans; then
  log "WARN: core-edge failed to start: recreating its containers"
  docker compose -f /data/core/edge/compose.yaml rm -fs >/dev/null 2>&1 || true
  docker compose -f /data/core/edge/compose.yaml up -d --remove-orphans
fi
# Caddyfile/cert changes need a reload (bind mounts are read at start).
docker compose -f /data/core/edge/compose.yaml restart caddy >/dev/null

# ---- 7. logs + metrics ---------------------------------------------------------
# /var/log/core/agent.log is tailed by the unified agent into core-log-cloud. claude-code-fleet's rsyslog rule
# (/etc/rsyslog.d/30-cc-orchestrator.conf) writes the cc-rc@<repo>/cc-agents output and unit events into it.
mkdir -p /var/log/core && touch /var/log/core/agent.log && chown syslog:adm /var/log/core/agent.log && chmod 640 /var/log/core/agent.log
cat > /etc/logrotate.d/core <<'ROT'
/var/log/core/*.log /var/log/core-bootstrap.log {
  weekly
  rotate 4
  compress
  missingok
  notifempty
  copytruncate
}
ROT
systemctl restart rsyslog
install_disk_metric_timer

log "=== cloud bootstrap done"
