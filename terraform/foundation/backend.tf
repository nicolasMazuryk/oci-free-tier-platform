# State lives in the bucket this layer creates (core-bucket-tfstate).
# First-ever deploy: `make bootstrap` creates a local backend_override.tf,
# applies, then migrates state here. See docs/runbooks/00-first-deploy.md.
terraform {
  backend "oci" {
    bucket              = "core-bucket-tfstate"
    key                 = "foundation/terraform.tfstate"
    region              = "uk-london-1"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }
}
