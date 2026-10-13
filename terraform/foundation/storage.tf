data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = oci_identity_compartment.core.id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "core-bucket-tfstate"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  freeform_tags  = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Keep old state versions bounded (Always Free: 20 GB object storage).
resource "oci_objectstorage_object_lifecycle_policy" "tfstate" {
  depends_on = [oci_identity_policy.objectstorage_service]
  namespace  = data.oci_objectstorage_namespace.ns.namespace
  bucket     = oci_objectstorage_bucket.tfstate.name

  rules {
    name        = "expire-old-state-versions"
    action      = "DELETE"
    is_enabled  = true
    target      = "previous-object-versions"
    time_amount = 90
    time_unit   = "DAYS"
  }
}
