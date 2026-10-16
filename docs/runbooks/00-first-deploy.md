# 00 – First deploy (empty tenancy to running core)

Expect about 45 minutes of work, plus waiting for emails and capacity.

## Prerequisites

- **OCI CLI** with a `DEFAULT` profile (`~/.oci/config`) for an admin user. The home region must be `uk-london-1`. Check with `oci os ns get`.
- **Terraform** 1.12 or later (it has the native `oci` backend), plus `jq`, `gh` and `rsync`.
- The **SSH key**: `ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/oci_core`.
- The **Cloudflare zone** `mazuryktech.com` is active on Free.
- The **hard-coded values** match your tenancy:
  - nothing: the namespace comes from `oci os ns get` and is passed to `terraform init` by the Makefile (`TF_CLI_ARGS_init`)
  - `zone_id` and `alerts_email`: set them in `terraform/<layer>/terraform.tfvars` (gitignored, see `terraform.tfvars.example`)

## 1. Foundation (state is bootstrapped locally, then migrated)

```bash
make bootstrap
```

- **What it does:** creates a temporary `backend_override.tf` (local backend) and applies. Then it removes the override, runs `terraform init -migrate-state` into `core-bucket-tfstate`, and deletes the local state files.
- **If the bucket already exists**, it only runs `init`.
- **Expected result:** about 28 resources. If you get `Compartment {core} does not exist` on the policies, that is IAM propagation lag. Re-run the command.

Then:
- **Confirm the ONS subscription email** sent to the alerts address. Until it is confirmed, alarms go nowhere.
- Check that `make plan-foundation` says "No changes".

## 2. Cloudflare

1. Create an API token in the Cloudflare dashboard (My Profile, then API Tokens, then Create Custom Token):
   - Zone / DNS / **Edit**
   - Zone / Zone Settings / **Edit**
   - Zone / SSL and Certificates / **Edit**
   - Zone Resources: Include, Specific zone, `mazuryktech.com`
2. Store the token. From a real terminal:
   `make secret-put NAME=core-secret-cf-api-token`
   From the `!` shell (no TTY), with the token on the clipboard:
   `f=$(mktemp) && pbpaste > "$f" && make secret-put NAME=core-secret-cf-api-token FILE="$f"; rm -f "$f"`
3. Apply:
   `make init-cloudflare apply-cloudflare`
   This creates DNS, the TLS settings, and the Origin CA cert, which goes into Vault.
4. Run `make plan-cloudflare`. It should say "No changes".

## 3. Core

```bash
make init-core apply-core
```

- This creates about 68 resources: network, NSGs, NLB, Bastion, VMs, volume, backup policy, logs and alarms.
- If you see **`Out of host capacity`** for A1, retry later, or set `app_ad_index = 1` (or 2) in `terraform/core/terraform.tfvars`.
  ops must stay in AD-1.
- Cloud-init runs `bootstrap.sh`. It takes about 4 minutes on app and about 12 minutes on ops (Micro).

Check progress:
```bash
make ssh VM=app CMD='cloud-init status; sudo grep "^\[" /var/log/core-bootstrap.log | tail'
make ssh VM=ops CMD='cloud-init status; sudo grep "^\[" /var/log/core-bootstrap.log | tail'
```

## 4. Verify

```bash
make plan-all                                  # no changes x3
make free-tier                                 # PASS
curl -sI https://mazuryktech.com | head -1     # 200
curl -sI https://status.mazuryktech.com | grep -i location   # -> /status/core (NOT /setup*)
curl -m 8 -k https://203.0.113.10           # must time out (Cloudflare-only)
make ssh VM=app CMD='echo | openssl s_client -connect 127.0.0.1:443 -servername mazuryktech.com 2>/dev/null | openssl x509 -noout -issuer'
```

Also check, in the console or CLI:
- every alarm is OK
- `core-log-app` has records
- the backup policy is attached to `core-bv-app-data`

## 5. Human hand-off (agent fleet)

These steps need a **real terminal**.

1. **GitHub fine-grained PAT** at https://github.com/settings/personal-access-tokens/new:
   - owner `nicolasMazuryk`
   - All repositories
   - Contents RW, Pull requests RW, Issues RW, Workflows RW, Metadata R
   - Store it: `make secret-put NAME=core-secret-github-pat` (or use the pbpaste variant above)
   - Then run `make host-sync VM=app`. Bootstrap runs `gh auth login --with-token`, `gh auth setup-git` and `git_protocol https` for `agent`.
2. **Claude login:**
   - `make ssh VM=app`
   - `sudo -iu agent claude auth login`. Open the URL and paste the code back.
3. **First repo:** `fleet add <repo>`, then `fleet attach <repo>`. Accept workspace trust and the Remote Control prompt, then detach with Ctrl-b d.
4. **Push notifications:** in `/config` (or in the app), turn on *Push when Claude decides* and *Push when actions required*.
5. **Tailscale (node `cloud`):** follow cc-orchestrator `docs/runbooks/tailscale.md`. In order:
   - apply its tailnet policy (it defines `tag:cloud`)
   - generate a reusable, tagged auth key
   - `make secret-put NAME=core-secret-tailscale-authkey`
   - `make host-sync VM=app`
   Until then, bootstrap logs "not in Vault yet: skipping tailscale up", and Bastion is the only way in.
6. **Uptime Kuma:** nothing to do.
   - The public status page and the standard monitors are provisioned by ops bootstrap.
   - The admin login (`/dashboard`) is `admin`, with the password in `core-secret-uptime-kuma-admin`; see [monitoring-alerts](monitoring-alerts.md).
