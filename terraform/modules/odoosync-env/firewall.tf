# Cloud Firewall for the environment (ADR-08 3.3, staging list). Attached by tag AND, when var.droplet_name is set, by droplet id.
# DigitalOcean drops outbound traffic when a firewall has no outbound rule, so the outbound rules are explicit.
locals {
  http_sources = var.public_http ? ["0.0.0.0/0", "::/0"] : var.https_cidrs
}

resource "digitalocean_firewall" "this" {
  name        = "${local.prefix}-fw"
  tags        = [digitalocean_tag.env.name]
  droplet_ids = [for id in local.droplet_ids : tonumber(id)]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.admin_ssh_cidrs
  }

  # Port 80 is public on purpose: Let's Encrypt HTTP-01 and the public sites (ADR-08 3.3).
  dynamic "inbound_rule" {
    for_each = length(local.http_sources) > 0 ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = "80"
      source_addresses = local.http_sources
    }
  }

  dynamic "inbound_rule" {
    for_each = length(var.https_cidrs) > 0 ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = "443"
      source_addresses = var.https_cidrs
    }
  }

  # Extra ports (for example Clover 8081 and Grafana 3001 on staging), each only from the CIDRs given.
  dynamic "inbound_rule" {
    for_each = { for k, r in var.extra_tcp_rules : k => r if length(r.cidrs) > 0 }
    content {
      protocol         = "tcp"
      port_range       = tostring(inbound_rule.value.port)
      source_addresses = inbound_rule.value.cidrs
    }
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound is open: omnisync has 84 outbound call sites to arbitrary hosts (ADR-08 3.3). Revisit after hypercare.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
