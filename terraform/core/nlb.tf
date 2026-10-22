resource "oci_network_load_balancer_network_load_balancer" "core" {
  compartment_id                 = local.compartment
  display_name                   = "core-nlb"
  subnet_id                      = oci_core_subnet.pub.id
  is_private                     = false
  is_preserve_source_destination = false
  network_security_group_ids     = [oci_core_network_security_group.nlb.id]
  freeform_tags                  = local.tags

  reserved_ips {
    id = local.f.nlb_public_ip_id
  }
}

resource "oci_network_load_balancer_backend_set" "https" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.core.id
  name                     = "core-bes-https"
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol           = "TCP"
    port               = 443
    interval_in_millis = 10000
    timeout_in_millis  = 3000
    retries            = 3
  }
}

resource "oci_network_load_balancer_listener" "https" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.core.id
  name                     = "core-lsn-https"
  default_backend_set_name = oci_network_load_balancer_backend_set.https.name
  port                     = 443
  protocol                 = "TCP"
}

# ---- egress proxy (gost on cloud, TLS + basic auth) -----------------------------
# Browser Use publishes no egress IP list, so :8443 is open to the internet (docs/adr/0006).
resource "oci_network_load_balancer_backend_set" "egress" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.core.id
  name                     = "core-bes-egress"
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol           = "TCP"
    port               = 8443
    interval_in_millis = 10000
    timeout_in_millis  = 3000
    retries            = 3
  }
}

resource "oci_network_load_balancer_listener" "egress" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.core.id
  name                     = "core-lsn-egress"
  default_backend_set_name = oci_network_load_balancer_backend_set.egress.name
  port                     = 8443
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_backend" "cloud_egress" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.core.id
  backend_set_name         = oci_network_load_balancer_backend_set.egress.name
  target_id                = oci_core_instance.cloud.id
  port                     = 8443
}
