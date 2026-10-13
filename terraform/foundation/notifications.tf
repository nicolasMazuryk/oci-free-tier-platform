resource "oci_ons_notification_topic" "alerts" {
  compartment_id = oci_identity_compartment.core.id
  name           = "core-topic-alerts"
  description    = "All core alarms and drift alerts"
  freeform_tags  = local.tags
}

resource "oci_ons_subscription" "alerts_email" {
  compartment_id = oci_identity_compartment.core.id
  topic_id       = oci_ons_notification_topic.alerts.id
  protocol       = "EMAIL"
  endpoint       = var.alerts_email
  freeform_tags  = local.tags
}

resource "oci_budget_budget" "monthly" {
  compartment_id         = var.tenancy_ocid
  display_name           = "core-budget-monthly"
  description            = "Guardrail: alerts on any spend (Always Free should be $0)"
  amount                 = var.budget_amount
  reset_period           = "MONTHLY"
  target_type            = "COMPARTMENT"
  targets                = [var.tenancy_ocid]
  processing_period_type = "MONTH"
  freeform_tags          = local.tags
}

resource "oci_budget_alert_rule" "pct" {
  for_each       = toset(["50", "100"])
  budget_id      = oci_budget_budget.monthly.id
  display_name   = "core-budget-actual-${each.key}pct"
  type           = "ACTUAL"
  threshold      = tonumber(each.key)
  threshold_type = "PERCENTAGE"
  recipients     = var.alerts_email
  message        = "OCI spend reached ${each.key}% of the ${var.budget_amount} budget. Something non-Always-Free is being billed."
  freeform_tags  = local.tags
}

resource "oci_budget_alert_rule" "forecast" {
  budget_id      = oci_budget_budget.monthly.id
  display_name   = "core-budget-forecast-100pct"
  type           = "FORECAST"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.alerts_email
  message        = "Forecast OCI spend exceeds the monthly budget."
  freeform_tags  = local.tags
}
