# Persistent public IP: Cloudflare DNS points here, so wiping the core layer
# (NLB included) never requires a DNS change.
resource "oci_core_public_ip" "nlb" {
  compartment_id = oci_identity_compartment.core.id
  display_name   = "core-pip-nlb"
  lifetime       = "RESERVED"
  freeform_tags  = local.tags

  lifecycle {
    prevent_destroy = true
    # The NLB attaches/detaches it; don't fight over assignment.
    ignore_changes = [private_ip_id]
  }
}

# Persistent egress IP: core-natgw uses it, so both VMs (and the tailnet exit
# node on cloud) keep one allowlistable source address across wipe/restore.
resource "oci_core_public_ip" "natgw" {
  compartment_id = oci_identity_compartment.core.id
  display_name   = "core-pip-natgw"
  lifetime       = "RESERVED"
  freeform_tags  = local.tags

  lifecycle {
    prevent_destroy = true
    # The NAT gateway attaches it; don't fight over assignment.
    ignore_changes = [private_ip_id]
  }
}
