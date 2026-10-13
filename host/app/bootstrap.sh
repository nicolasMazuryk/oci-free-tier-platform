#!/usr/bin/env bash
# core-vm-app bootstrap. Idempotent: safe to re-run (cloud-init first boot,
# `make host-sync VM=app`, or after a restore from backup).
source /opt/core/lib.sh
exec > >(tee -a /var/log/core-bootstrap.log) 2>&1
log "=== app bootstrap start"
export DEBIAN_FRONTEND=noninteractive
DATA_DEV=/dev/oracleoci/oraclevdb

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
apt-get install -y -qq git tmux gh jq build-essential rsync unzip ca-certificates curl >/dev/null
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
if [[ ! -x /data/home/agent/.local/bin/claude ]]; then
  log "installing Claude Code for agent"
  as_agent 'curl -fsSL https://claude.ai/install.sh | bash' || log "WARN: claude install failed (re-run bootstrap)"
fi
as_agent 'grep -q ".local/bin" ~/.bashrc || echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.bashrc'
as_agent 'mkdir -p ~/.claude && [ -f ~/.claude/settings.json ] || echo "{ \"permissions\": { \"defaultMode\": \"auto\" } }" > ~/.claude/settings.json'
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

# ---- 5. fleet tooling --------------------------------------------------------
install -m 0644 /opt/core/agent@.service /etc/systemd/system/agent@.service
install -m 0755 /opt/core/fleet /usr/local/bin/fleet
systemctl daemon-reload
for d in /data/fleet/*/; do
  [[ -d "$d/.git" ]] || continue
  r="$(basename "$d")"
  # never restart a running agent (users may be attached to its tmux session)
  if systemctl is-active --quiet "agent@$r"; then
    systemctl enable --quiet "agent@$r"; log "agent@$r already active: left running"
  else
    systemctl enable --now "agent@$r" && log "started agent@$r"
  fi
done

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
# agent@* unit events -> /var/log/core/agent.log (tailed by the unified agent into core-log-app)
mkdir -p /var/log/core && touch /var/log/core/agent.log && chown syslog:adm /var/log/core/agent.log && chmod 640 /var/log/core/agent.log
cat > /etc/rsyslog.d/30-core-agent.conf <<'RSYSLOG'
if ($programname startswith "agent@") or ($programname == "systemd" and $msg contains "agent@") then /var/log/core/agent.log
RSYSLOG
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

log "=== app bootstrap done"
