# Apex + wildcard -> persistent reserved IP (core-pip-nlb), proxied.
# The wildcard covers every <slug>.domain / <slug>-<svc>.domain hostname.
resource "cloudflare_dns_record" "apex" {
  zone_id = var.zone_id
  name    = local.domain
  type    = "A"
  content = local.ip
  proxied = true
  ttl     = 1
  comment = "core-nlb (managed by terraform/cloudflare)"
}

resource "cloudflare_dns_record" "wildcard" {
  zone_id = var.zone_id
  name    = "*.${local.domain}"
  type    = "A"
  content = local.ip
  proxied = true
  ttl     = 1
  comment = "core-nlb wildcard (managed by terraform/cloudflare)"
}

# ---- OCI Email Delivery (DNS only) ----
resource "cloudflare_dns_record" "spf" {
  zone_id = var.zone_id
  name    = local.domain
  type    = "TXT"
  content = "\"v=spf1 include:${local.f.spf_include} ~all\""
  proxied = false
  ttl     = 3600
  comment = "SPF for OCI Email Delivery"
}

resource "cloudflare_dns_record" "dkim" {
  zone_id = var.zone_id
  name    = trimsuffix(local.f.dkim_dns_name, ".")
  type    = "CNAME"
  content = local.f.dkim_cname_value
  proxied = false
  ttl     = 3600
  comment = "DKIM core-dkim for OCI Email Delivery"
}

resource "cloudflare_dns_record" "dmarc" {
  zone_id = var.zone_id
  name    = "_dmarc.${local.domain}"
  type    = "TXT"
  content = "\"v=DMARC1; p=none; rua=mailto:${local.f.alerts_email}\""
  proxied = false
  ttl     = 3600
  comment = "DMARC (monitor only)"
}
