output "firewall_name" {
  value = module.env.firewall_name
}

output "attached_droplet_id" {
  value = module.env.attached_droplet_id
}

output "env_tag" {
  value = module.env.env_tag
}

output "pgdata_volume_id" {
  value = module.env.pgdata_volume_id
}

output "bucket_names" {
  value = module.env.bucket_names
}
