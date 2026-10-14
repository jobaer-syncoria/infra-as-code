# Droplet alert policies (ADR-08 3.11): CPU > 80% for 10 min, memory > 85% for 10 min, disk > 80%, load5 > 4.
# They need do-agent on the droplet (the droplet's "monitoring" option). Destinations: e-mail and/or Slack.
locals {
  alert_policies = {
    cpu    = { type = "v1/insights/droplet/cpu", value = var.cpu_threshold, window = "10m", description = "CPU above ${var.cpu_threshold}%" }
    memory = { type = "v1/insights/droplet/memory_utilization_percent", value = var.memory_threshold, window = "10m", description = "Memory above ${var.memory_threshold}%" }
    disk   = { type = "v1/insights/droplet/disk_utilization_percent", value = var.disk_threshold, window = "10m", description = "Disk above ${var.disk_threshold}%" }
    load5  = { type = "v1/insights/droplet/load_5", value = var.load5_threshold, window = "10m", description = "5 minute load above ${var.load5_threshold}" }
  }
  has_slack = var.slack_channel != "" && var.slack_webhook_url != ""
}

resource "digitalocean_monitor_alert" "droplet" {
  for_each    = var.alerts_enabled ? local.alert_policies : {}
  description = "${local.prefix}: ${each.value.description}"
  type        = each.value.type
  compare     = "GreaterThan"
  value       = each.value.value
  window      = each.value.window
  enabled     = true
  # The provider refuses an empty entities list, so the argument is left out when no droplet is attached (the tag selects).
  entities = length(local.droplet_ids) > 0 ? [for id in local.droplet_ids : tostring(id)] : null
  tags     = [digitalocean_tag.env.name]

  alerts {
    email = var.alert_emails
    dynamic "slack" {
      for_each = local.has_slack ? [1] : []
      content {
        channel = var.slack_channel
        url     = var.slack_webhook_url
      }
    }
  }
}

# External uptime checks and their alerts (down, slow). Off until URLs are given.
resource "digitalocean_uptime_check" "this" {
  for_each = var.uptime_enabled ? var.uptime_targets : {}
  name     = "${local.prefix}-${each.key}"
  target   = each.value
  type     = startswith(each.value, "https") ? "https" : "http"
  regions  = var.uptime_regions
  enabled  = true
}

resource "digitalocean_uptime_alert" "down" {
  for_each   = digitalocean_uptime_check.this
  name       = "${each.value.name}-down"
  check_id   = each.value.id
  type       = "down"
  threshold  = 1
  comparison = "less_than"
  period     = "2m"

  notifications {
    email = var.alert_emails
    dynamic "slack" {
      for_each = local.has_slack ? [1] : []
      content {
        channel = var.slack_channel
        url     = var.slack_webhook_url
      }
    }
  }
}

resource "digitalocean_uptime_alert" "slow" {
  for_each   = digitalocean_uptime_check.this
  name       = "${each.value.name}-slow"
  check_id   = each.value.id
  type       = "latency"
  threshold  = 2000
  comparison = "greater_than"
  period     = "5m"

  notifications {
    email = var.alert_emails
    dynamic "slack" {
      for_each = local.has_slack ? [1] : []
      content {
        channel = var.slack_channel
        url     = var.slack_webhook_url
      }
    }
  }
}
