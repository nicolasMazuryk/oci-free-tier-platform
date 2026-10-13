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
# Never expose Kuma's first-run setup page: bind to localhost, finish setup
# with the admin login from Vault, and only then publish on 0.0.0.0.
open_port 3001
mkdir -p /opt/uptime-kuma
install -m 0644 /opt/core/uptime-kuma/compose.yaml /opt/uptime-kuma/compose.yaml
kc() { KUMA_BIND="$1" docker compose -f /opt/uptime-kuma/compose.yaml "${@:2}"; }
kuma_ctr() { docker compose -f /opt/uptime-kuma/compose.yaml ps -q uptime-kuma; }
kuma_wait() { for _ in $(seq 1 60); do curl -fs -o /dev/null http://127.0.0.1:3001/ && return 0; sleep 5; done; return 1; }
kuma_js() { docker cp /opt/core/uptime-kuma/kuma-init.js "$(kuma_ctr)":/tmp/kuma-init.js >/dev/null; docker exec -i "$(kuma_ctr)" node /tmp/kuma-init.js; }
# Deterministic check (no socket): DB configured and at least one user row.
kuma_users() {
  [[ -f /opt/uptime-kuma/data/db-config.json && -f /opt/uptime-kuma/data/kuma.db && -n "$(kuma_ctr)" ]] || { echo 0; return; }
  docker exec "$(kuma_ctr)" node -e 'const s=require("/app/node_modules/@louislam/sqlite3");const d=new s.Database("/app/data/kuma.db",s.OPEN_READONLY);d.get("select count(*) n from user",(e,r)=>{console.log(e?0:r.n);d.close()})' 2>/dev/null || echo 0
}
kuma_initialised() { [[ "$(kuma_users)" -ge 1 ]] 2>/dev/null; }
if kuma_initialised; then
  log "uptime-kuma already initialised"
else
  log "uptime-kuma not initialised: starting on 127.0.0.1 only"
  kc 127.0.0.1 up -d --remove-orphans
  kuma_wait || { log "FATAL: uptime-kuma did not start"; exit 1; }
  if curl -fs http://127.0.0.1:3001/setup-database-info | jq -e '.needSetup == true' >/dev/null; then
    log "uptime-kuma: selecting SQLite"
    curl -fs -X POST -H 'Content-Type: application/json' -d '{"dbConfig":{"type":"sqlite"}}' \
      http://127.0.0.1:3001/setup-database >/dev/null
    sleep 10; kuma_wait
    for _ in $(seq 1 30); do curl -fs http://127.0.0.1:3001/setup-database-info 2>/dev/null | jq -e '.needSetup == true' >/dev/null || break; sleep 5; done
  fi
  creds="$(secret_get core-secret-uptime-kuma-admin)" || { log "FATAL: core-secret-uptime-kuma-admin missing; Kuma stays local-only"; exit 1; }
  for i in $(seq 1 12); do
    out="$(printf '%s' "$creds" | kuma_js 2>&1)" && break
    log "uptime-kuma setup attempt $i: $out"; sleep 10
  done
  unset creds
  kuma_initialised || { log "FATAL: uptime-kuma setup failed; Kuma stays local-only"; exit 1; }
  log "uptime-kuma initialised (admin login in Vault: core-secret-uptime-kuma-admin)"
fi
kc 0.0.0.0 up -d --remove-orphans

# cron: weekly Cloudflare IP drift check, disk metric every 5 min
install -m 0755 /opt/core/cf-ip-drift.sh /usr/local/bin/core-cf-ip-drift
cat > /etc/cron.d/core-ops <<CRON
# managed by /opt/core/bootstrap.sh
SHELL=/bin/bash
17 6 * * 1 root /usr/local/bin/core-cf-ip-drift >> /var/log/core-cf-ip-drift.log 2>&1
CRON
install_disk_metric_timer

log "=== ops bootstrap done"
