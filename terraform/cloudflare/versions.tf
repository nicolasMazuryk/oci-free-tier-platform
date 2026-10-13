terraform {
  required_version = ">= 1.12.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.9"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.27"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
}

# The scoped API token never lives in git or tfvars: it is read from Vault
# (put there with `make secret-put NAME=core-secret-cf-api-token`).
provider "cloudflare" {
  api_token = trimspace(base64decode(data.oci_secrets_secretbundle.cf_token.secret_bundle_content[0].content))
}
