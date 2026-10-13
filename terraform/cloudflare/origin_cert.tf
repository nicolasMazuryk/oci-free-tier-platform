# Cloudflare Origin CA cert (15 years) for apex + wildcard. The private key is
# generated here and only ever stored in Vault (and the private state bucket).
resource "tls_private_key" "origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem
  dns_names       = [local.domain, "*.${local.domain}"]
  subject {
    common_name  = local.domain
    organization = "core"
  }
}

resource "cloudflare_origin_ca_certificate" "origin" {
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = [local.domain, "*.${local.domain}"]
  request_type       = "origin-rsa"
  requested_validity = 5475
}

resource "oci_vault_secret" "origin_cert" {
  compartment_id = local.f.core_compartment_id
  vault_id       = local.f.vault_id
  key_id         = local.f.key_id
  secret_name    = "core-secret-cf-origin-cert"
  description    = "Cloudflare Origin CA certificate (PEM) for ${local.domain}, *.${local.domain}"
  freeform_tags  = local.tags
  secret_content {
    content_type = "BASE64"
    content      = base64encode(cloudflare_origin_ca_certificate.origin.certificate)
  }
}

resource "oci_vault_secret" "origin_key" {
  compartment_id = local.f.core_compartment_id
  vault_id       = local.f.vault_id
  key_id         = local.f.key_id
  secret_name    = "core-secret-cf-origin-key"
  description    = "Private key (PEM) for core-secret-cf-origin-cert"
  freeform_tags  = local.tags
  secret_content {
    content_type = "BASE64"
    content      = base64encode(tls_private_key.origin.private_key_pem)
  }
}
