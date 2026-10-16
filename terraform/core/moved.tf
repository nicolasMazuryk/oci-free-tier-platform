# 2026-10: the app VM was renamed to `cloud` (OS hostname, VNIC label, display names, addresses).
# These blocks move the existing state so the rename is in-place updates only: zero destroys.
# Keep them: a state that predates the rename (a backup restore of an old state version) still needs them.

moved {
  from = oci_core_instance.app
  to   = oci_core_instance.cloud
}

moved {
  from = oci_core_volume.app_data
  to   = oci_core_volume.cloud_data
}

moved {
  from = oci_core_volume_attachment.app_data
  to   = oci_core_volume_attachment.cloud_data
}

moved {
  from = oci_core_volume_backup_policy_assignment.app_data
  to   = oci_core_volume_backup_policy_assignment.cloud_data
}

moved {
  from = oci_network_load_balancer_backend.app
  to   = oci_network_load_balancer_backend.cloud
}

moved {
  from = oci_core_network_security_group.app
  to   = oci_core_network_security_group.cloud
}

moved {
  from = oci_core_network_security_group_security_rule.nlb_out_app
  to   = oci_core_network_security_group_security_rule.nlb_out_cloud
}

moved {
  from = oci_core_network_security_group_security_rule.app_in_cf
  to   = oci_core_network_security_group_security_rule.cloud_in_cf
}

moved {
  from = oci_core_network_security_group_security_rule.app_in_nlb_hc
  to   = oci_core_network_security_group_security_rule.cloud_in_nlb_hc
}

moved {
  from = oci_core_network_security_group_security_rule.app_in_ops_probe
  to   = oci_core_network_security_group_security_rule.cloud_in_ops_probe
}

moved {
  from = oci_core_network_security_group_security_rule.app_in_ssh
  to   = oci_core_network_security_group_security_rule.cloud_in_ssh
}

moved {
  from = oci_core_network_security_group_security_rule.app_out_all
  to   = oci_core_network_security_group_security_rule.cloud_out_all
}

moved {
  from = oci_logging_log.app
  to   = oci_logging_log.cloud
}

moved {
  from = oci_logging_unified_agent_configuration.app
  to   = oci_logging_unified_agent_configuration.cloud
}

moved {
  from = oci_monitoring_alarm.core["core-alarm-app-cpu"]
  to   = oci_monitoring_alarm.core["core-alarm-cloud-cpu"]
}

moved {
  from = oci_monitoring_alarm.core["core-alarm-app-mem"]
  to   = oci_monitoring_alarm.core["core-alarm-cloud-mem"]
}

moved {
  from = oci_monitoring_alarm.core["core-alarm-app-disk"]
  to   = oci_monitoring_alarm.core["core-alarm-cloud-disk"]
}
