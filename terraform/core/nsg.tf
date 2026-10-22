# Cloudflare IPv4 edge ranges (https://www.cloudflare.com/ips-v4).
# A weekly cron on core-vm-ops alerts if these drift from the NSG.
data "http" "cf_ipv4" {
  url = "https://www.cloudflare.com/ips-v4"
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not fetch Cloudflare IPv4 ranges."
    }
  }
}

locals {
  cf_ipv4 = sort([for l in split("\n", data.http.cf_ipv4.response_body) : trimspace(l) if can(cidrhost(trimspace(l), 0))])
}

# ---- NLB: only Cloudflare may reach :443 ----
resource "oci_core_network_security_group" "nlb" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-nsg-nlb"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "nlb_in_cf" {
  for_each                  = toset(local.cf_ipv4)
  network_security_group_id = oci_core_network_security_group.nlb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "cloudflare"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# The single 0.0.0.0/0 ingress exception: the egress proxy on :8443 (docs/adr/0006).
resource "oci_core_network_security_group_security_rule" "nlb_in_egress" {
  network_security_group_id = oci_core_network_security_group.nlb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  description               = "egress proxy (Browser Use, TLS + basic auth)"
  tcp_options {
    destination_port_range {
      min = 8443
      max = 8443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_out_cloud" {
  network_security_group_id = oci_core_network_security_group.nlb.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.cloud.id
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_out_cloud_egress" {
  network_security_group_id = oci_core_network_security_group.nlb.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.cloud.id
  tcp_options {
    destination_port_range {
      min = 8443
      max = 8443
    }
  }
}

# ---- cloud VM ----
resource "oci_core_network_security_group" "cloud" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-nsg-cloud"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "cloud_in_cf" {
  for_each                  = toset(local.cf_ipv4)
  network_security_group_id = oci_core_network_security_group.cloud.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "cloudflare"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cloud_in_egress" {
  network_security_group_id = oci_core_network_security_group.cloud.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  description               = "egress proxy (NLB preserves the source IP)"
  tcp_options {
    destination_port_range {
      min = 8443
      max = 8443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cloud_in_nlb_hc" {
  network_security_group_id = oci_core_network_security_group.cloud.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.nlb.id
  description               = "nlb health checks"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cloud_in_ops_probe" {
  network_security_group_id = oci_core_network_security_group.cloud.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.ops.id
  description               = "uptime kuma origin probe from ops"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cloud_in_ssh" {
  network_security_group_id = oci_core_network_security_group.cloud.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "${oci_bastion_bastion.core.private_endpoint_ip_address}/32"
  description               = "bastion ssh"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cloud_out_all" {
  network_security_group_id = oci_core_network_security_group.cloud.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}

# ---- ops VM ----
resource "oci_core_network_security_group" "ops" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-nsg-ops"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "ops_in_kuma" {
  network_security_group_id = oci_core_network_security_group.ops.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.cloud.id
  description               = "uptime kuma from cloud (caddy)"
  tcp_options {
    destination_port_range {
      min = 3001
      max = 3001
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ops_in_ssh" {
  network_security_group_id = oci_core_network_security_group.ops.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "${oci_bastion_bastion.core.private_endpoint_ip_address}/32"
  description               = "bastion ssh"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ops_out_all" {
  network_security_group_id = oci_core_network_security_group.ops.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}
