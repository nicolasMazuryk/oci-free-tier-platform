terraform {
  backend "oci" {
    bucket              = "core-bucket-tfstate"
    namespace           = "YOUR_OCI_NAMESPACE"
    key                 = "cloudflare/terraform.tfstate"
    region              = "uk-london-1"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }
}
