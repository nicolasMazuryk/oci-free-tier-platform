terraform {
  required_version = ">= 1.12.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
}
