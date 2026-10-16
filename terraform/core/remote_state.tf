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
  f           = data.terraform_remote_state.foundation.outputs
  compartment = local.f.core_compartment_id
  domain      = local.f.domain
  tags = {
    "scope"      = "core"
    "managed-by" = "terraform"
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = local.f.tenancy_ocid
}
