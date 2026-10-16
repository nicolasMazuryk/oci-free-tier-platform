variable "tenancy_ocid" {
  description = "Unused here; accepted so the Makefile can export one TF_VAR set for every layer."
  type        = string
  default     = null
}

variable "user_ocid" {
  description = "Unused here (see tenancy_ocid)."
  type        = string
  default     = null
}

variable "region" {
  type    = string
  default = "uk-london-1"
}

variable "oci_profile" {
  type    = string
  default = "DEFAULT"
}

variable "zone_id" {
  description = "Cloudflare zone id of the domain (Free plan)."
  type        = string
}

variable "cf_token_secret_name" {
  type    = string
  default = "core-secret-cf-api-token"
}

variable "oci_namespace" {
  description = "Object Storage namespace holding the Terraform state bucket (oci os ns get). Exported by the Makefile as TF_VAR_oci_namespace."
  type        = string
}
