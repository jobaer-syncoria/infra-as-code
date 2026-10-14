# Non-secret outputs only (docs/environments.md). Nothing sensitive is ever output.
output "firewall_id" {
  value = digitalocean_firewall.this.id
}

output "firewall_name" {
  value = digitalocean_firewall.this.name
}

output "attached_droplet_id" {
  description = "ID of the droplet the firewall and alerts were attached to by name, or null"
  value       = length(local.droplet_ids) > 0 ? local.droplet_ids[0] : null
}

output "env_tag" {
  description = "Tag a human can put on a droplet so the firewall and the alerts select it"
  value       = digitalocean_tag.env.name
}

output "vpc_id" {
  value = length(digitalocean_vpc.this) > 0 ? digitalocean_vpc.this[0].id : null
}

output "pgdata_volume_id" {
  description = "ID to attach by hand: doctl compute volume-action attach <id> <droplet-id>"
  value       = length(digitalocean_volume.pgdata) > 0 ? digitalocean_volume.pgdata[0].id : null
}

output "bucket_names" {
  value = concat(keys(digitalocean_spaces_bucket.open), keys(digitalocean_spaces_bucket.protected))
}

output "uptime_check_ids" {
  value = { for k, c in digitalocean_uptime_check.this : k => c.id }
}
