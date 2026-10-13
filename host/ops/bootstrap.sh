#!/usr/bin/env bash
# core-vm-ops bootstrap (E2.1.Micro, 1 GB RAM). Idempotent.
source /opt/core/lib.sh
exec > >(tee -a /var/log/core-bootstrap.log) 2>&1
log "=== ops bootstrap start"
export DEBIAN_FRONTEND=noninteractive

ensure_swap 2G
apt-get update -qq
apt-get install -y -qq jq curl rsync ca-certificates >/dev/null
install_oci_cli
install_docker /var/lib/docker

# Uptime Kuma (status.<domain> via Caddy on core-vm-app)
open_port 3001
mkdir -p /opt/uptime-kuma
install -m 0644 /opt/core/uptime-kuma/compose.yaml /opt/uptime-kuma/compose.yaml
docker compose -f /opt/uptime-kuma/compose.yaml up -d --remove-orphans

# cron: weekly Cloudflare IP drift check, disk metric every 5 min
install -m 0755 /opt/core/cf-ip-drift.sh /usr/local/bin/core-cf-ip-drift
cat > /etc/cron.d/core-ops <<CRON
# managed by /opt/core/bootstrap.sh
SHELL=/bin/bash
17 6 * * 1 root /usr/local/bin/core-cf-ip-drift >> /var/log/core-cf-ip-drift.log 2>&1
CRON
install_disk_metric_timer

log "=== ops bootstrap done"
