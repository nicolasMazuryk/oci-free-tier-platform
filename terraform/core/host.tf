# Cloud-init: ship host/common + host/<role> to /opt/core (gzip+base64) and run
# bootstrap.sh. VMs ignore later user_data changes; use `make host-sync`.
locals {
  host_root = "${path.module}/../../host"

  host_files = {
    for role in ["cloud", "ops"] : role => merge(
      { for f in fileset("${local.host_root}/common", "**") : f => "${local.host_root}/common/${f}" },
      { for f in fileset("${local.host_root}/${role}", "**") : f => "${local.host_root}/${role}/${f}" },
    )
  }

  core_env = {
    for role in ["cloud", "ops"] : role => join("\n", [for k, v in {
      ROLE                    = role
      DOMAIN                  = local.domain
      REGION                  = var.region
      COMPARTMENT_ID          = local.compartment
      PROJECTS_COMPARTMENT_ID = local.f.projects_compartment_id
      VAULT_ID                = local.f.vault_id
      TOPIC_ID                = local.f.alerts_topic_id
      ALERTS_EMAIL            = local.f.alerts_email
      CLOUD_IP                = var.cloud_private_ip
      OPS_IP                  = var.ops_private_ip
      GIT_USER_NAME           = var.git_user_name
      GIT_USER_EMAIL          = var.git_user_email
      NODE_MAJOR              = "24"
      DISK_METRIC_MOUNTS      = role == "cloud" ? "/ /data" : "/"
    } : "${k}=\"${v}\""])
  }

  cloud_init = {
    for role in ["cloud", "ops"] : role => "#cloud-config\n${yamlencode({
      write_files = concat(
        [for dst, src in local.host_files[role] : {
          path        = "/opt/core/${dst}"
          encoding    = "gz+b64"
          content     = base64gzip(file(src))
          permissions = (endswith(dst, ".sh") || dst == "fleet") ? "0755" : "0644"
        }],
        [{
          path        = "/opt/core/core.env"
          content     = "${local.core_env[role]}\n"
          permissions = "0644"
        }],
      )
      runcmd = [["bash", "/opt/core/bootstrap.sh"]]
    })}"
  }
}
