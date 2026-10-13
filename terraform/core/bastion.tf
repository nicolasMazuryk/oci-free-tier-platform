resource "oci_bastion_bastion" "core" {
  compartment_id               = local.compartment
  name                         = "core-bastion"
  bastion_type                 = "STANDARD"
  target_subnet_id             = oci_core_subnet.priv.id
  client_cidr_block_allow_list = var.bastion_client_cidrs
  max_session_ttl_in_seconds   = 10800
  freeform_tags                = local.tags
}
