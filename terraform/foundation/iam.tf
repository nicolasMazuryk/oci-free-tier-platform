resource "oci_identity_compartment" "core" {
  compartment_id = var.tenancy_ocid
  name           = "core"
  description    = "Shared core infrastructure (agent fleet + web hosting)"
  enable_delete  = false
  freeform_tags  = local.tags
}

resource "oci_identity_compartment" "projects" {
  compartment_id = var.tenancy_ocid
  name           = "projects"
  description    = "Project-specific resources (<slug>- prefix, project tag)"
  enable_delete  = false
  freeform_tags  = local.tags
}

# Every instance in the core compartment gets the instance principal.
resource "oci_identity_dynamic_group" "compute" {
  compartment_id = var.tenancy_ocid
  name           = "core-dg-compute"
  description    = "All compute instances in compartment ${oci_identity_compartment.core.name}"
  matching_rule  = "ALL {instance.compartment.id = '${oci_identity_compartment.core.id}'}"
  freeform_tags  = local.tags
}

resource "oci_identity_policy" "compute" {
  compartment_id = var.tenancy_ocid
  name           = "core-pol-compute"
  description    = "Instance principal permissions for core VMs"
  freeform_tags  = local.tags
  statements = [
    # The egress proxy password is delivered to cloud by claude-code-fleet install (from the Mac), never read
    # through the instance principal. The Cloudflare API token is used only by the Mac's terraform/cloudflare and
    # carries zone-wide DNS/SSL edit, so cloud never reads it either. `make check-iam` asserts both exclusions.
    # browser-use-api-key stays readable: the cloud brain calls Browser Use (shield login, browser-use executor).
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read secret-family in compartment ${oci_identity_compartment.core.name} where all {target.secret.name != 'core-secret-egress-proxy-password', target.secret.name != 'core-secret-cf-api-token'}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read secret-family in compartment ${oci_identity_compartment.projects.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to use metrics in compartment ${oci_identity_compartment.core.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to use ons-topics in compartment ${oci_identity_compartment.core.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read virtual-network-family in compartment ${oci_identity_compartment.core.name}",
    # list NSG security rules (CF drift check) needs the "use" verb
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to use network-security-groups in compartment ${oci_identity_compartment.core.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to use log-content in compartment ${oci_identity_compartment.core.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read instances in compartment ${oci_identity_compartment.core.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to manage object-family in compartment ${oci_identity_compartment.projects.name}",
  ]
}

# Object Storage needs this to run lifecycle policies (old state versions).
resource "oci_identity_policy" "objectstorage_service" {
  compartment_id = var.tenancy_ocid
  name           = "core-pol-objectstorage"
  description    = "Lets Object Storage run lifecycle policies in core"
  freeform_tags  = local.tags
  statements = [
    "Allow service objectstorage-${var.region} to manage object-family in compartment ${oci_identity_compartment.core.name}",
  ]
}
