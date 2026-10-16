data "terraform_remote_state" "foundation" {
  backend = "oci"
  config = {
    bucket              = "core-bucket-tfstate"
    namespace           = var.oci_namespace
    key                 = "foundation/terraform.tfstate"
    region              = "uk-london-1"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }
}

locals {
  f      = data.terraform_remote_state.foundation.outputs
  domain = local.f.domain
  ip     = local.f.nlb_public_ip
  tags = {
    "scope"      = "core"
    "managed-by" = "terraform"
  }
}

data "oci_vault_secrets" "cf_token" {
  compartment_id = local.f.core_compartment_id
  vault_id       = local.f.vault_id
  name           = var.cf_token_secret_name
  state          = "ACTIVE"
}

data "oci_secrets_secretbundle" "cf_token" {
  secret_id = try(data.oci_vault_secrets.cf_token.secrets[0].id, "missing")

  lifecycle {
    precondition {
      condition     = length(data.oci_vault_secrets.cf_token.secrets) > 0
      error_message = "Vault secret core-secret-cf-api-token not found. Create a scoped Cloudflare API token, then run: make secret-put NAME=core-secret-cf-api-token"
    }
  }
}
