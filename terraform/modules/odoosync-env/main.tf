locals {
  prefix      = "odoosync-${var.env_short}"
  env_tag     = "odoosync-${var.environment}"
  has_droplet = var.droplet_name != ""
  droplet_ids = local.has_droplet ? [data.digitalocean_droplet.this[0].id] : []
}

# The droplet is only READ. This module never creates, changes or destroys it.
data "digitalocean_droplet" "this" {
  count = local.has_droplet ? 1 : 0
  name  = var.droplet_name
}

resource "digitalocean_tag" "base" {
  name = "odoosync"
}

# Tags select the firewall and the alerts. A tag only reaches a droplet when a human (or a later droplet module) puts it on
# the droplet, so attaching by droplet name (var.droplet_name) is the way that works today.
resource "digitalocean_tag" "env" {
  name = local.env_tag
}

resource "digitalocean_vpc" "this" {
  count    = var.create_vpc ? 1 : 0
  name     = "${local.prefix}-${var.region}"
  region   = var.region
  ip_range = var.vpc_ip_range
}

resource "digitalocean_project" "this" {
  name        = "odoosync"
  description = "SyncoriaConnector ${var.environment} (managed by Terraform)"
  purpose     = "Web Application"
  environment = var.environment == "production" ? "Production" : "Staging"
}

resource "digitalocean_project_resources" "this" {
  project = digitalocean_project.this.id
  resources = concat(
    local.has_droplet ? [data.digitalocean_droplet.this[0].urn] : [],
    [for v in digitalocean_volume.pgdata : v.urn],
    [for b in digitalocean_spaces_bucket.open : b.urn],
    [for b in digitalocean_spaces_bucket.protected : b.urn],
  )
}
