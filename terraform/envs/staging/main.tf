module "env" {
  source = "../../modules/odoosync-env"

  environment  = "staging"
  env_short    = "stg"
  region       = var.region
  droplet_name = var.droplet_name

  admin_ssh_cidrs = var.admin_ssh_cidrs
  public_http     = var.public_http
  https_cidrs     = var.https_cidrs
  extra_tcp_rules = {
    clover  = { port = 8081, cidrs = var.clover_ui_cidrs }
    grafana = { port = 3001, cidrs = var.grafana_cidrs }
  }

  create_pgdata_volume = var.create_pgdata_volume
  pgdata_size_gib      = var.pgdata_size_gib
  buckets = var.walg_bucket_name == "" ? {} : {
    (var.walg_bucket_name) = { versioned = true, noncurrent_days = 7 }
  }

  alert_emails      = var.alert_emails
  slack_channel     = var.slack_channel
  slack_webhook_url = var.slack_webhook_url
  uptime_enabled    = var.uptime_enabled
  uptime_targets    = var.uptime_targets
}
