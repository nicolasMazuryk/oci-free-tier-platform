# ---- Logging: core-logs / core-log-app (unified agent on core-vm-app) --------
resource "oci_logging_log_group" "core" {
  compartment_id = local.compartment
  display_name   = "core-logs"
  description    = "Core host logs"
  freeform_tags  = local.tags
}

resource "oci_logging_log" "app" {
  log_group_id       = oci_logging_log_group.core.id
  display_name       = "core-log-app"
  log_type           = "CUSTOM"
  is_enabled         = true
  retention_duration = 30
  freeform_tags      = local.tags
}

resource "oci_logging_unified_agent_configuration" "app" {
  compartment_id = local.compartment
  display_name   = "core-uac-app"
  description    = "Docker container logs, agent@* unit events, bootstrap log -> core-log-app"
  is_enabled     = true
  freeform_tags  = local.tags

  service_configuration {
    configuration_type = "LOGGING"
    destination {
      log_object_id = oci_logging_log.app.id
    }
    sources {
      name        = "docker"
      source_type = "LOG_TAIL"
      paths       = ["/data/docker/containers/*/*-json.log"]
      parser {
        parser_type    = "JSON"
        field_time_key = "time" # docker json-file: RFC3339 with nanoseconds
        time_type      = "STRING"
        time_format    = "%Y-%m-%dT%H:%M:%S.%N%z"
      }
    }
    sources {
      name        = "agents"
      source_type = "LOG_TAIL"
      paths       = ["/var/log/core/agent.log"]
      parser {
        parser_type = "NONE"
      }
    }
    sources {
      name        = "bootstrap"
      source_type = "LOG_TAIL"
      paths       = ["/var/log/core-bootstrap.log"]
      parser {
        parser_type = "NONE"
      }
    }
  }

  group_association {
    group_list = [local.f.dynamic_group_id]
  }
}

# ---- Alarms -> core-topic-alerts ---------------------------------------------
locals {
  alarms = {
    "core-alarm-app-cpu" = {
      ns    = "oci_computeagent"
      query = "CpuUtilization[5m]{resourceId = \"${oci_core_instance.app.id}\"}.mean() > 90"
      sev   = "WARNING"
      wait  = "PT15M"
      body  = "core-vm-app CPU > 90% for 15 min. Check heavy builds/tests: make ssh VM=app, then top / fleet ls."
    }
    "core-alarm-app-mem" = {
      ns    = "oci_computeagent"
      query = "MemoryUtilization[5m]{resourceId = \"${oci_core_instance.app.id}\"}.mean() > 90"
      sev   = "WARNING"
      wait  = "PT10M"
      body  = "core-vm-app memory > 90% for 10 min (16 GB swap absorbs spikes; sustained = too many agents/containers)."
    }
    "core-alarm-app-disk" = {
      ns    = "core_custom"
      query = "disk_used_pct[5m].max() > 85"
      sev   = "CRITICAL"
      wait  = "PT5M"
      body  = "A core filesystem is > 85% full (dimensions: host, mount). Prune: docker system prune, git worktree prune, pnpm store prune."
    }
    "core-alarm-nlb-health" = {
      ns    = "oci_nlb"
      query = "HealthyBackends[1m]{resourceId = \"${oci_network_load_balancer_network_load_balancer.core.id}\"}.min() < 1"
      sev   = "CRITICAL"
      wait  = "PT5M"
      body  = "core-nlb has no healthy backend: Caddy (core-edge) on core-vm-app is not answering on 443. All sites are down."
    }
  }
}

resource "oci_monitoring_alarm" "core" {
  for_each                     = local.alarms
  compartment_id               = local.compartment
  metric_compartment_id        = local.compartment
  display_name                 = each.key
  namespace                    = each.value.ns
  query                        = each.value.query
  severity                     = each.value.sev
  pending_duration             = each.value.wait
  body                         = each.value.body
  destinations                 = [local.f.alerts_topic_id]
  is_enabled                   = true
  repeat_notification_duration = "PT4H"
  message_format               = "ONS_OPTIMIZED"
  freeform_tags                = local.tags
}

# Disk metric stops arriving = the reporting VM (or its timer) is dead.
resource "oci_monitoring_alarm" "disk_absent" {
  compartment_id        = local.compartment
  metric_compartment_id = local.compartment
  display_name          = "core-alarm-metrics-absent"
  namespace             = "core_custom"
  # grouped by the stable host name: a rebuilt VM (new resourceId) must not leave
  # the old instance stream "absent" forever
  query                        = "disk_used_pct[5m]{mount = \"/\"}.groupBy(host).absent()"
  severity                     = "CRITICAL"
  pending_duration             = "PT15M"
  body                         = "No disk metric from a core VM for 15 min: the VM is down or core-disk-metric.timer stopped."
  destinations                 = [local.f.alerts_topic_id]
  is_enabled                   = true
  repeat_notification_duration = "PT4H"
  message_format               = "ONS_OPTIMIZED"
  freeform_tags                = local.tags
}
