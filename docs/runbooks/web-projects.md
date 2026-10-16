# Web projects (`<slug>.mazuryktech.com`)

- The wildcard DNS record and the wildcard Origin cert already cover `*.mazuryktech.com`. **There is no DNS or cert step.**
- Hostnames are one level deep only. Use `<slug>.mazuryktech.com` for sites and `<slug>-<svc>.mazuryktech.com` for APIs.

## Project contract

Each repo ships:
- a `Dockerfile` that listens on 3000 and serves `/health`
- a `compose.yaml` on network `edge`, with Caddy labels:

```yaml
name: acme
services:
  api:
    build: .
    restart: unless-stopped
    env_file: .env
    networks: [edge]
    labels:
      caddy: acme-api.mazuryktech.com
      caddy.import: cf_tls                     # serve the Cloudflare Origin cert
      caddy.reverse_proxy: "{{upstreams 3000}}"
  web:                                         # optional Next.js (output: "standalone")
    build: ./web
    restart: unless-stopped
    networks: [edge]
    labels:
      caddy: acme.mazuryktech.com
      caddy.import: cf_tls
      caddy.reverse_proxy: "{{upstreams 3000}}"
networks:
  edge: { external: true }
```

- Read the client IP from the `CF-Connecting-IP` header.
- Everything is arm64, which happens automatically when you build on the VM.

## Add

1. Create the secrets. They go to compartment `projects`:
   `make secret-put NAME=acme-secret-db-url` (or `FILE=...`)
2. Clone and render the env file on cloud (as `agent`). Run `secret_get` in a **root** shell, because `/opt/core/lib.sh` uses the instance principal:
   ```bash
   git clone https://github.com/nicolasMazuryk/acme.git /data/projects/acme && cd /data/projects/acme
   sudo bash -c 'source /opt/core/lib.sh; echo "DATABASE_URL=$(secret_get acme-secret-db-url)"' > .env && chmod 600 .env
   docker compose up -d --build
   ```
3. Check it: `curl -sI https://acme-api.mazuryktech.com/health`.
4. Add an Uptime Kuma monitor for `https://acme-api.mazuryktech.com/health`.
5. Tag OCI resources: name them `acme-*`, put them in compartment `projects`, and add freeform tag `project=acme`.

## Update

`git pull && docker compose up -d --build`. Agents can do this themselves.

## Remove

```bash
cd /data/projects/acme && docker compose down -v && cd / && rm -rf /data/projects/acme
```

Then delete the OCI resources tagged `project=acme`, and schedule deletion of the `acme-secret-*` secrets:
`oci vault secret schedule-secret-deletion --secret-id ...`.

## Notes and limits

- **Cloudflare Free:**
  - Requests time out after about 100 s. Use streaming/SSE or async jobs for long work.
  - Uploads are capped at 100 MB.
  - WebSockets work.
- When a container stops, its route disappears. Unknown hosts get the catch-all `404 no such site`.
- Outbound port 25 is blocked. Send mail through Email Delivery: `core-secret-smtp` (JSON) on port 587, from `noreply@mazuryktech.com`.
- **Traces:**
  - OTLP to `core-apm`, using `service.name=<slug>-<svc>`.
  - The endpoint is `make output-foundation ARGS='-raw apm_data_upload_endpoint'`.
  - The data key is `core-secret-apm-private-key`.
- **Another domain:**
  1. Add the zone to Cloudflare and proxy it to `203.0.113.10`.
  2. Issue an Origin CA cert for it (extend `terraform/cloudflare`).
  3. Store it in Vault, and add a `tls` snippet for it in `host/cloud/edge/Caddyfile.tmpl`.
