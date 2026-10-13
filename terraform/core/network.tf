resource "oci_core_vcn" "core" {
  compartment_id = local.compartment
  display_name   = "core-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "core"
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-igw"
  enabled        = true
  freeform_tags  = local.tags
}

resource "oci_core_nat_gateway" "natgw" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-natgw"
  freeform_tags  = local.tags
}

data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "sgw" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-sgw"
  freeform_tags  = local.tags
  services {
    service_id = data.oci_core_services.all.services[0].id
  }
}

resource "oci_core_route_table" "pub" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-rt-pub"
  freeform_tags  = local.tags
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_route_table" "priv" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-rt-priv"
  freeform_tags  = local.tags
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.natgw.id
  }
  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.sgw.id
  }
}

# Security lists are deliberately minimal (egress + path-MTU ICMP);
# all ingress is expressed with NSGs in nsg.tf.
resource "oci_core_security_list" "base" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.core.id
  display_name   = "core-sl-base"
  freeform_tags  = local.tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "1" # ICMP
    icmp_options {
      type = 3
    }
  }
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "pub" {
  compartment_id             = local.compartment
  vcn_id                     = oci_core_vcn.core.id
  display_name               = "core-snet-pub"
  cidr_block                 = var.pub_cidr
  dns_label                  = "pub"
  route_table_id             = oci_core_route_table.pub.id
  security_list_ids          = [oci_core_security_list.base.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "priv" {
  compartment_id             = local.compartment
  vcn_id                     = oci_core_vcn.core.id
  display_name               = "core-snet-priv"
  cidr_block                 = var.priv_cidr
  dns_label                  = "priv"
  route_table_id             = oci_core_route_table.priv.id
  security_list_ids          = [oci_core_security_list.base.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}
