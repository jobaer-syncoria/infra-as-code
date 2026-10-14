# Module odoosync-env

Everything around the droplet, as code. **It does not create, change or destroy the droplet**: the droplet is only looked up by
name (`droplet_name`) so the firewall, the project and the alerts can attach to it.

| Resource | What | Notes |
|---|---|---|
| Tags | `odoosync`, `odoosync-<environment>` | A tag reaches a droplet only when a human puts it there; attaching by `droplet_name` is what works today |
| VPC (optional) | `create_vpc` | Off by default: a droplet cannot be moved into a new VPC by this module |
| Project | `odoosync` | Receives the droplet, volume and buckets |
| Cloud Firewall | `odoosync-<env>-fw` | 22 from `admin_ssh_cidrs` only (0.0.0.0/0 refused), 80 public (`public_http`), 443 from `https_cidrs`, extra ports (Clover 8081, Grafana 3001) only from the CIDRs you list, ICMP, explicit outbound |
| pgdata volume | `create_pgdata_volume`, `pgdata_size_gib` >= 20 | `prevent_destroy`; created without a filesystem; **never attached by Terraform** (a human runs `doctl compute volume-action attach`) |
| Spaces buckets | `buckets` (open), `protected_buckets` (`prevent_destroy`) | private, versioned, noncurrent versions expire |
| Alert policies | CPU 80%, memory 85%, disk 80%, load5 4 (10 min windows) | need do-agent (`monitoring = true`) on the droplet; e-mail and optional Slack |
| Uptime checks | `uptime_enabled`, `uptime_targets` | each with a down alert (1 region, 2 min) and a latency alert (2 s, 5 min) |

Secrets: the Slack webhook is `sensitive` and comes from `TF_VAR_slack_webhook_url`. Nothing secret is a default or an output.

Tests: `cd terraform/modules/odoosync-env && terraform init -backend=false && terraform test` (12 cases against a mock provider).
