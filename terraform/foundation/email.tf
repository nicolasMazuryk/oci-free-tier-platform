resource "oci_email_email_domain" "main" {
  compartment_id = oci_identity_compartment.core.id
  name           = var.domain
  description    = "Email Delivery domain for ${var.domain}"
  freeform_tags  = local.tags
}

resource "oci_email_dkim" "main" {
  email_domain_id = oci_email_email_domain.main.id
  name            = "core-dkim"
  description     = "DKIM selector for ${var.domain} (CNAME published by the cloudflare layer)"
  freeform_tags   = local.tags
}

resource "oci_email_sender" "noreply" {
  compartment_id = oci_identity_compartment.core.id
  email_address  = "noreply@${var.domain}"
  freeform_tags  = local.tags
}

resource "oci_identity_smtp_credential" "core" {
  user_id     = var.user_ocid
  description = "core-smtp (Email Delivery, stored in core-secret-smtp)"
}

resource "oci_vault_secret" "smtp" {
  compartment_id = oci_identity_compartment.core.id
  vault_id       = oci_kms_vault.main.id
  key_id         = oci_kms_key.main.id
  secret_name    = "core-secret-smtp"
  description    = "Email Delivery SMTP credentials (JSON: host, port, username, password, from)"
  freeform_tags  = local.tags

  secret_content {
    content_type = "BASE64"
    content = base64encode(jsonencode({
      host     = local.smtp_endpoint
      port     = 587
      username = oci_identity_smtp_credential.core.username
      password = oci_identity_smtp_credential.core.password
      from     = oci_email_sender.noreply.email_address
    }))
  }
}
