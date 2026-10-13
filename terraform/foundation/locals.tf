locals {
  tags = {
    "scope"      = "core"
    "managed-by" = "terraform"
  }
  # OCI Email Delivery SPF include for EMEA regions (uk-london-1).
  spf_include   = "eu.rp.oracleemaildelivery.com"
  smtp_endpoint = "smtp.email.${var.region}.oci.oraclecloud.com"
}
