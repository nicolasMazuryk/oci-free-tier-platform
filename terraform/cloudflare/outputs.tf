output "zone_id" { value = var.zone_id }
output "origin_cert_secret_id" { value = oci_vault_secret.origin_cert.id }
output "origin_key_secret_id" { value = oci_vault_secret.origin_key.id }
output "origin_cert_expires_on" { value = cloudflare_origin_ca_certificate.origin.expires_on }
output "dns_records" {
  value = {
    apex     = cloudflare_dns_record.apex.name
    wildcard = cloudflare_dns_record.wildcard.name
    dkim     = cloudflare_dns_record.dkim.name
  }
}
