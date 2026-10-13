data "oci_core_images" "ubuntu" {
  for_each                 = { app = "VM.Standard.A1.Flex", ops = "VM.Standard.E2.1.Micro" }
  compartment_id           = local.compartment
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = each.value
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-24\\.04-(aarch64-)?[0-9.]+-[0-9]+$"] # excludes Minimal/GPU
    regex  = true
  }
}

locals {
  ad_names = data.oci_identity_availability_domains.ads.availability_domains[*].name
  ssh_key  = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# ---- core-vm-app: A1 Flex (agent fleet + Caddy + web containers) ------------
resource "oci_core_instance" "app" {
  compartment_id      = local.compartment
  availability_domain = local.ad_names[var.app_ad_index]
  display_name        = "core-vm-app"
  shape               = "VM.Standard.A1.Flex"
  freeform_tags       = merge(local.tags, { "role" = "app" })

  shape_config {
    ocpus         = var.app_ocpus
    memory_in_gbs = var.app_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu["app"].images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
    boot_volume_vpus_per_gb = 10
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.priv.id
    private_ip       = var.app_private_ip
    assign_public_ip = false
    hostname_label   = "app"
    display_name     = "core-vnic-app"
    nsg_ids          = [oci_core_network_security_group.app.id]
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  agent_config {
    is_monitoring_disabled = false
    is_management_disabled = false
    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Custom Logs Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }

  metadata = {
    ssh_authorized_keys = local.ssh_key
    user_data           = base64encode(local.cloud_init["app"])
  }

  lifecycle {
    ignore_changes = [metadata["user_data"], source_details[0].source_id]
  }
}

# 100 GB /data: repos, worktrees, agent home, Docker. Restorable from backup.
resource "oci_core_volume" "app_data" {
  compartment_id      = local.compartment
  availability_domain = oci_core_instance.app.availability_domain
  display_name        = "core-bv-app-data"
  size_in_gbs         = var.data_volume_gb
  vpus_per_gb         = 10
  freeform_tags       = merge(local.tags, { "role" = "app-data" })

  dynamic "source_details" {
    for_each = var.data_volume_backup_id == "" ? [] : [var.data_volume_backup_id]
    content {
      type = "volumeBackup"
      id   = source_details.value
    }
  }

  lifecycle {
    ignore_changes = [source_details]
  }
}

resource "oci_core_volume_attachment" "app_data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.app.id
  volume_id       = oci_core_volume.app_data.id
  display_name    = "core-att-app-data"
  device          = "/dev/oracleoci/oraclevdb"
}

# Daily incremental, keep 3 (of 5 free backups).
resource "oci_core_volume_backup_policy" "daily_3d" {
  compartment_id = local.compartment
  display_name   = "core-bkp-daily-3d"
  freeform_tags  = local.tags

  schedules {
    backup_type       = "INCREMENTAL"
    period            = "ONE_DAY"
    retention_seconds = 3 * 24 * 3600
    hour_of_day       = 3
    offset_type       = "STRUCTURED"
    time_zone         = "UTC"
  }
}

resource "oci_core_volume_backup_policy_assignment" "app_data" {
  asset_id  = oci_core_volume.app_data.id
  policy_id = oci_core_volume_backup_policy.daily_3d.id
}

# ---- core-vm-ops: E2.1.Micro (Uptime Kuma, cron) -----------------------------
resource "oci_core_instance" "ops" {
  compartment_id      = local.compartment
  availability_domain = local.ad_names[0] # E2.1.Micro only exists in AD-1
  display_name        = "core-vm-ops"
  shape               = "VM.Standard.E2.1.Micro"
  freeform_tags       = merge(local.tags, { "role" = "ops" })

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu["ops"].images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
    boot_volume_vpus_per_gb = 10
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.priv.id
    private_ip       = var.ops_private_ip
    assign_public_ip = false
    hostname_label   = "ops"
    display_name     = "core-vnic-ops"
    nsg_ids          = [oci_core_network_security_group.ops.id]
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  agent_config {
    is_monitoring_disabled = false
    is_management_disabled = false
    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }

  metadata = {
    ssh_authorized_keys = local.ssh_key
    user_data           = base64encode(local.cloud_init["ops"])
  }

  lifecycle {
    ignore_changes = [metadata["user_data"], source_details[0].source_id]
  }
}

# ---- NLB backend -------------------------------------------------------------
resource "oci_network_load_balancer_backend" "app" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.core.id
  backend_set_name         = oci_network_load_balancer_backend_set.https.name
  target_id                = oci_core_instance.app.id
  port                     = 443
}
