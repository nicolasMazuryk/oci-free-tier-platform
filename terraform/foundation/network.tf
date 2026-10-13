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
