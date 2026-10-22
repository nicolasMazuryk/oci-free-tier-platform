# Shared helpers for host scripts. Installed to /opt/core/lib.sh.
# Reads /opt/core/core.env (rendered by terraform/core at VM creation).
set -euo pipefail
[[ -r /opt/core/core.env ]] && source /opt/core/core.env
# core.env rendered before the app -> cloud rename (2026-10) still says APP_IP / ROLE="app".
# migrate_core_env (run by bootstrap as root) rewrites it; until then, map the old name.
: "${CLOUD_IP:=${APP_IP:-}}"
[[ ${ROLE:-} == app ]] && ROLE=cloud
export OCI_CLI_AUTH=instance_principal
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# One-time, idempotent rename of pre-2026-10 keys in /opt/core/core.env (host-sync never ships core.env).
migrate_core_env() {
  local f=/opt/core/core.env
  [[ -w $f ]] || return 0
  if grep -qE '^(APP_IP=|ROLE="app"$)' "$f"; then
    sed -i -e 's/^APP_IP=/CLOUD_IP=/' -e 's/^ROLE="app"$/ROLE="cloud"/' "$f"
    log "core.env: renamed APP_IP -> CLOUD_IP, ROLE app -> cloud"
  fi
}

# secret_get <name> -> prints decoded value, returns 1 if missing.
# Looks in core first, then projects (for <slug>-secret-*).
secret_get() {
  local name="$1" out
  out="$(oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$VAULT_ID" \
          --secret-name "$name" --query 'data."secret-bundle-content".content' --raw-output 2>/dev/null)" || return 1
  [[ -n "$out" && "$out" != null ]] || return 1
  printf '%s' "$out" | base64 -d
}

# notify <title> <body> -> publish to core-topic-alerts
notify() {
  oci ons message publish --topic-id "$TOPIC_ID" --title "$1" --body "$2" >/dev/null
}

install_oci_cli() {
  if [[ -x /opt/oci-cli/bin/oci ]]; then return 0; fi
  log "installing OCI CLI into /opt/oci-cli"
  apt-get install -y -qq python3-venv >/dev/null
  python3 -m venv /opt/oci-cli
  /opt/oci-cli/bin/pip install -q --upgrade pip
  /opt/oci-cli/bin/pip install -q oci-cli
  ln -sf /opt/oci-cli/bin/oci /usr/local/bin/oci
}

install_docker() { # install_docker <data-root> [classic]
  # "classic" = disable Docker 29's containerd image store, so images, layers and
  # container snapshots live under <data-root> (overlay2) instead of
  # /var/lib/containerd on the boot volume. Required on cloud: /data is what gets
  # backed up and restored, and a restore must bring containers back intact.
  local data_root="$1" mode="${2:-}" features="" restart=0
  [[ $mode == classic ]] && features=',
  "features": { "containerd-snapshotter": false }'
  mkdir -p /etc/docker "$data_root"
  local want
  want="$(printf '{ "data-root": "%s",\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }%s }\n' "$data_root" "$features")"
  if [[ "$(cat /etc/docker/daemon.json 2>/dev/null)" != "$want" ]]; then
    printf '%s' "$want" > /etc/docker/daemon.json; restart=1
  fi
  if ! command -v docker >/dev/null; then
    log "installing Docker"
    curl -fsSL https://get.docker.com | sh >/dev/null
  fi
  systemctl enable --now docker
  if (( restart )) || [[ "$(docker info -f '{{.DockerRootDir}}')" != "$data_root" ]]; then
    log "docker daemon.json changed: restarting docker"; systemctl restart docker
  fi
  docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null
}

ensure_swap() { # ensure_swap <size e.g. 16G>
  if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
    log "creating /swapfile ($1)"
    [[ -f /swapfile ]] || { fallocate -l "$1" /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; }
    swapon /swapfile
  fi
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -q vm.swappiness=10; echo 'vm.swappiness=10' > /etc/sysctl.d/99-core-swap.conf
}

# Oracle's Ubuntu image ships an iptables INPUT chain ending in REJECT.
# Open a TCP port live and in /etc/iptables/rules.v4 (without saving Docker's rules).
open_port() {
  local port="$1" rules=/etc/iptables/rules.v4
  iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT 5 -p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT
  if [[ -f $rules ]] && ! grep -q -- "--dport $port -j ACCEPT" "$rules"; then
    sed -i "/-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT/a -A INPUT -p tcp -m state --state NEW -m tcp --dport $port -j ACCEPT" "$rules"
  fi
}

install_disk_metric_timer() {
  install -m 0755 /opt/core/disk-metric.sh /usr/local/bin/core-disk-metric
  cat > /etc/systemd/system/core-disk-metric.service <<UNIT
[Unit]
Description=Post filesystem usage to OCI Monitoring (core_custom/disk_used_pct)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/core-disk-metric
UNIT
  cat > /etc/systemd/system/core-disk-metric.timer <<UNIT
[Unit]
Description=Every 5 minutes: core-disk-metric
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now core-disk-metric.timer
}

# Enable IPv4/IPv6 forwarding now and across reboots (Tailscale exit node). Idempotent.
enable_ip_forward() {
  local conf=/etc/sysctl.d/99-core-ipforward.conf want
  want='net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1'
  [[ "$(cat "$conf" 2>/dev/null)" == "$want" ]] || printf '%s\n' "$want" > "$conf"
  sysctl -q -p "$conf" >/dev/null
}

# Allow inbound UDP on one interface only (e.g. mosh over tailscale0), live and in
# /etc/iptables/rules.v4. Inserted just before the image's final REJECT.
#   allow_udp_on_iface tailscale0 60000:61000
allow_udp_on_iface() {
  local ifc="$1" ports="$2" rules=/etc/iptables/rules.v4 pos
  local spec="-i $ifc -p udp -m udp --dport $ports -j ACCEPT"
  # shellcheck disable=SC2086  # $spec is a fixed list of iptables words
  if ! iptables -C INPUT $spec 2>/dev/null; then
    pos="$(iptables -L INPUT -n --line-numbers | awk '$2 == "REJECT" { print $1; exit }')"
    # shellcheck disable=SC2086
    iptables -I INPUT "${pos:-1}" $spec
  fi
  if [[ -f $rules ]] && ! grep -qxF -- "-A INPUT $spec" "$rules"; then
    sed -i "/^-A INPUT -j REJECT/i -A INPUT $spec" "$rules"
  fi
}
