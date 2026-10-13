resource "oci_apm_apm_domain" "core" {
  compartment_id = oci_identity_compartment.core.id
  display_name   = "core-apm"
  description    = "OpenTelemetry traces from web projects (service.name=<slug>-<svc>)"
  is_free_tier   = true
  freeform_tags  = local.tags
}

data "oci_apm_data_keys" "core" {
  apm_domain_id = oci_apm_apm_domain.core.id
}

locals {
  apm_keys = { for k in data.oci_apm_data_keys.core.data_keys : lower(k.type) => k.value }
}

resource "oci_vault_secret" "apm" {
  for_each       = toset(["public", "private"])
  compartment_id = oci_identity_compartment.core.id
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.main.id
  secret_name    = "core-secret-apm-${each.key}-key"
  description    = "core-apm ${each.key} data key (OTLP auth: 'dataKey <value>')"
  freeform_tags  = local.tags

  secret_content {
    content_type = "BASE64"
    content      = base64encode(local.apm_keys[each.key])
  }
}
