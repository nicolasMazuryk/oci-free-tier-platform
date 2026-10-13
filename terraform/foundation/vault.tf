# DEFAULT (shared) vault with a SOFTWARE key: both Always Free.
resource "oci_kms_vault" "main" {
  compartment_id = oci_identity_compartment.core.id
  display_name   = "core-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_kms_key" "main" {
  compartment_id      = oci_identity_compartment.core.id
  display_name        = "core-key-main"
  management_endpoint = oci_kms_vault.main.management_endpoint
  protection_mode     = "SOFTWARE"
  freeform_tags       = local.tags

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  lifecycle {
    prevent_destroy = true
  }
}
