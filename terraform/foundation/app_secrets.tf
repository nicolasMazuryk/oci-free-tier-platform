# Uptime Kuma admin: generated here (persistent layer) so a rebuilt ops VM can
# complete Kuma's first-run setup itself before status.<domain> is exposed.
resource "random_password" "kuma_admin" {
  length  = 32
  special = false
}

resource "oci_vault_secret" "kuma_admin" {
  compartment_id = oci_identity_compartment.core.id
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.main.id
  secret_name    = "core-secret-uptime-kuma-admin"
  description    = "Uptime Kuma admin login (JSON: user, password); used by ops bootstrap"
  freeform_tags  = local.tags

  secret_content {
    content_type = "BASE64"
    content      = base64encode(jsonencode({ user = "admin", password = random_password.kuma_admin.result }))
  }
}
