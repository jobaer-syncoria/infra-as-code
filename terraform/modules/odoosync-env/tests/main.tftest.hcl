# Logic tests for the module, run with `terraform test` against a MOCK provider: no DigitalOcean account, no token.
mock_provider "digitalocean" {
  mock_data "digitalocean_droplet" {
    defaults = {
      id   = "123456"
      urn  = "do:droplet:123456"
      name = "staging-droplet"
    }
  }
}

variables {
  environment     = "staging"
  env_short       = "stg"
  region          = "tor1"
  admin_ssh_cidrs = ["203.0.113.10/32"]
}

run "defaults_open_only_ssh_http_icmp" {
  command = plan
  assert {
    condition     = length(digitalocean_firewall.this.inbound_rule) == 3
    error_message = "By default only SSH, HTTP and ICMP are open."
  }
  assert {
    condition     = length(digitalocean_firewall.this.outbound_rule) == 3
    error_message = "Outbound must be explicit (tcp, udp, icmp), or DigitalOcean drops all egress."
  }
  assert {
    condition     = length(digitalocean_volume.pgdata) == 0 && length(digitalocean_monitor_alert.droplet) == 4
    error_message = "No volume by default, and four alert policies (cpu, memory, disk, load)."
  }
}

run "ssh_to_the_world_is_refused" {
  command = plan
  variables {
    admin_ssh_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.admin_ssh_cidrs]
}

run "empty_ssh_list_is_refused" {
  command = plan
  variables {
    admin_ssh_cidrs = []
  }
  expect_failures = [var.admin_ssh_cidrs]
}

run "extra_ports_only_when_cidrs_are_given" {
  command = plan
  variables {
    extra_tcp_rules = {
      clover  = { port = 8081, cidrs = ["203.0.113.10/32"] }
      grafana = { port = 3001, cidrs = [] }
    }
    https_cidrs = ["203.0.113.10/32"]
  }
  assert {
    condition     = length(digitalocean_firewall.this.inbound_rule) == 5
    error_message = "SSH, HTTP, ICMP, HTTPS and Clover (8081) = 5. Grafana has no CIDRs, so no rule."
  }
}

run "http_not_public_uses_https_cidrs" {
  command = plan
  variables {
    public_http = false
    https_cidrs = ["203.0.113.10/32"]
  }
  assert {
    condition     = length(digitalocean_firewall.this.inbound_rule) == 4
    error_message = "SSH, HTTP (restricted), ICMP, HTTPS."
  }
}

run "volume_needs_a_size" {
  command = plan
  variables {
    create_pgdata_volume = true
  }
  expect_failures = [digitalocean_volume.pgdata]
}

run "volume_too_small_is_refused" {
  command = plan
  variables {
    create_pgdata_volume = true
    pgdata_size_gib      = 10
  }
  expect_failures = [var.pgdata_size_gib]
}

run "volume_is_created_with_a_size" {
  command = plan
  variables {
    create_pgdata_volume = true
    pgdata_size_gib      = 20
  }
  assert {
    condition     = length(digitalocean_volume.pgdata) == 1 && digitalocean_volume.pgdata[0].size == 20
    error_message = "One 20 GiB volume expected."
  }
}

run "buckets_are_created" {
  command = plan
  variables {
    buckets           = { "example-stg-walg" = { versioned = true, noncurrent_days = 7 } }
    protected_buckets = { "example-prod-backups" = { versioned = true, noncurrent_days = 7 } }
  }
  assert {
    condition     = length(digitalocean_spaces_bucket.open) == 1 && length(digitalocean_spaces_bucket.protected) == 1
    error_message = "One open and one protected bucket expected."
  }
}

run "alerts_can_be_switched_off" {
  command = plan
  variables {
    alerts_enabled = false
  }
  assert {
    condition     = length(digitalocean_monitor_alert.droplet) == 0
    error_message = "alerts_enabled = false must create no alert policy."
  }
}

run "uptime_checks_follow_the_targets" {
  command = plan
  variables {
    uptime_enabled = true
    uptime_targets = { admin = "http://203.0.113.9/", clover = "https://203.0.113.9:8081/" }
  }
  assert {
    condition     = length(digitalocean_uptime_check.this) == 2 && length(digitalocean_uptime_alert.down) == 2 && length(digitalocean_uptime_alert.slow) == 2
    error_message = "Two checks, each with a down and a slow alert."
  }
}

run "existing_droplet_is_looked_up_not_created" {
  command = plan
  variables {
    droplet_name = "staging-droplet"
  }
  assert {
    condition     = length(data.digitalocean_droplet.this) == 1 && tostring(output.attached_droplet_id) == "123456"
    error_message = "The droplet must be read through the data source and its id used."
  }
}
