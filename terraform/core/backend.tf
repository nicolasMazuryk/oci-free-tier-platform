terraform {
  backend "oci" {
    bucket              = "core-bucket-tfstate"
    key                 = "core/terraform.tfstate"
    region              = "uk-london-1"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }
}
