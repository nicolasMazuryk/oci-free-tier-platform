variable "tenancy_ocid" {
  type    = string
  default = null
}
variable "user_ocid" {
  type    = string
  default = null
}
variable "region" {
  type    = string
  default = "uk-london-1"
}
variable "oci_profile" {
  type    = string
  default = "DEFAULT"
}

variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "pub_cidr" {
  type    = string
  default = "10.0.1.0/24"
}
variable "priv_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "bastion_client_cidrs" {
  description = "CIDRs allowed to open Bastion sessions (sessions still need ~/.ssh/oci_core)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---- compute ----
variable "cloud_ad_index" {
  description = "AD for core-vm-cloud (0=AD-1). Change if A1 capacity is exhausted. ops must stay in AD-1 (E2.1.Micro)."
  type        = number
  default     = 0
}
variable "cloud_ocpus" {
  type    = number
  default = 2
}
variable "cloud_memory_gb" {
  type    = number
  default = 12
}
variable "cloud_private_ip" {
  type    = string
  default = "10.0.2.10"
}
variable "ops_private_ip" {
  type    = string
  default = "10.0.2.20"
}
variable "boot_volume_gb" {
  type    = number
  default = 50
}
variable "data_volume_gb" {
  type    = number
  default = 100
}
variable "data_volume_backup_id" {
  description = "Restore: create core-bv-cloud-data from this volume backup OCID instead of empty."
  type        = string
  default     = ""
}
variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/oci_core.pub"
}
variable "git_user_name" {
  type    = string
  default = "nicolasMazuryk"
}
variable "git_user_email" {
  type    = string
  default = "12008114+nicolasMazuryk@users.noreply.github.com"
}

variable "oci_namespace" {
  description = "Object Storage namespace holding the Terraform state bucket (oci os ns get). Exported by the Makefile as TF_VAR_oci_namespace."
  type        = string
}
