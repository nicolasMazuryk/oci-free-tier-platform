variable "tenancy_ocid" {
  description = "Tenancy OCID (Makefile exports it from ~/.oci/config)."
  type        = string
}

variable "user_ocid" {
  description = "OCI user that owns the Email Delivery SMTP credential (Makefile exports it from ~/.oci/config)."
  type        = string
}

variable "region" {
  type    = string
  default = "uk-london-1"
}

variable "oci_profile" {
  type    = string
  default = "DEFAULT"
}

variable "domain" {
  description = "Apex domain served through Cloudflare and used for Email Delivery."
  type        = string
  default     = "mazuryktech.com"
}

variable "alerts_email" {
  description = "Email subscribed to core-topic-alerts and budget alerts."
  type        = string
  default     = "alerts@example.com"
}

variable "budget_amount" {
  description = "Monthly budget (account currency). Alerts at 50% and 100%."
  type        = number
  default     = 1
}
