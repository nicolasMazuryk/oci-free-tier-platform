# Secrets: put, read, rotate

Every secret lives in `core-vault`, encrypted with `core-key-main`.
- `core-secret-*` goes in compartment `core`.
- `<slug>-secret-*` goes in compartment `projects`.

## Put or update (laptop)

```bash
make secret-put NAME=core-secret-github-pat               # hidden prompt, asked twice (real terminal)
make secret-put NAME=acme-secret-db-url FILE=./value.txt  # from a file
```

No TTY (the `!` shell in Claude Code)? Copy the value to the clipboard, then:
```bash
f=$(mktemp) && pbpaste > "$f" && make secret-put NAME=<name> FILE="$f"; rm -f "$f"; printf '' | pbcopy
```

How `secret-put` handles the value:
- It never puts the value on argv. It writes a 0600 temp JSON file for `oci vault secret create-base64` / `update-base64`.
- An update creates a new CURRENT version.
- A secret that is PENDING_DELETION is refused, with a hint to cancel the deletion.

## Read

- **On a VM** (root, instance principal): `sudo bash -c 'source /opt/core/lib.sh; secret_get <name>'`
- **On the laptop:**
  `oci secrets secret-bundle get-secret-bundle-by-name --vault-id <vault> --secret-name <name> --query 'data."secret-bundle-content".content' --raw-output | base64 -d`
  The vault id comes from `make output-foundation ARGS='-raw vault_id'`.

## Rotation per secret

| Secret | Rotate how | Then |
|---|---|---|
| `core-secret-cf-api-token` | Roll the token in Cloudflare, then `secret-put` | `make plan-cloudflare` (it reads the new value) |
| `core-secret-github-pat` | Regenerate the fine-grained PAT (same permissions), then `secret-put` | `make host-sync VM=cloud` re-logs in `agent` |
| `core-secret-cf-origin-cert` / `-key` | `make apply-cloudflare ARGS='-replace=tls_private_key.origin'` issues a new key, CSR and Origin cert, and updates Vault | `make host-sync VM=cloud` reinstalls the cert and restarts Caddy |
| `core-secret-smtp` | `make apply-foundation ARGS='-replace=oci_identity_smtp_credential.core'` | Apps re-read the secret, or re-render `.env` |
| `core-secret-apm-*-key` | Rotate the data key in the APM console, then `make apply-foundation` (the secret is rebuilt from the data source) | Redeploy the instrumented apps |
| `core-secret-uptime-kuma-admin` | `make apply-foundation ARGS='-replace=random_password.kuma_admin'` (Terraform owns this secret: do not `secret-put` it) | Read the new value from Vault and set it in Kuma (Settings, then Security, then Change Password). Bootstrap only uses it for first-run setup. |
| `<slug>-secret-*` | `secret-put` | Re-render the project's `.env` and run `docker compose up -d` |
| `core-secret-tailscale-authkey` | **Not rotated.** It holds a Tailscale **OAuth client secret** (`tskey-client-…`, scope *Auth Keys: Write*, tag `tag:cloud`), which does not expire. Replace it only if it leaks or the OAuth client is deleted: admin console → Settings → Trust credentials → OAuth → generate a new client (same scope and tag) → `secret-put` → delete the old client. Details: claude-code-fleet `docs/runbooks/tailscale.md` §2 | Nothing: a joined node keeps working without it. It is only read when the node has no state (first deploy, `make restore BACKUP=none`) |
| `core-secret-ntfy-topic` | claude-code-fleet `docs/runbooks/rotate-secrets.md` | claude-code-fleet `./install.sh cloud` |

## Delete

`oci vault secret schedule-secret-deletion --secret-id <id> --time-of-deletion <RFC3339 1-30 days ahead>`

A secret in PENDING_DELETION still holds its name. Cancel the deletion with `oci vault secret cancel-secret-deletion --secret-id <id>`.

## Never

- Never put a secret in git, `*.tfvars`, a chat message, or a command line.
- Remember that Terraform-generated secrets also live in the state bucket (`core-bucket-tfstate`, private, versioned). Treat bucket access like Vault access.
