# Module odoosync-env: everything around the droplet. It does NOT create or manage the droplet: it only looks it up by name
# (var.droplet_name) to attach the firewall, the project and the alerts. No secret is ever a default or an output.

variable "environment" {
  description = "staging or production"
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "env_short" {
  description = "Short name used in resource names: stg or prod"
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug, for example tor1. No default on purpose."
  type        = string
}

variable "droplet_name" {
  description = "Name of the EXISTING droplet to attach to (looked up, never created). Empty = attach to the environment tag only."
  type        = string
  default     = ""
}

# ---- network ---------------------------------------------------------------------------------------------------------------
variable "create_vpc" {
  description = "Create a VPC. Leave false when the droplet already sits in a VPC (a droplet cannot be moved by this module)."
  type        = bool
  default     = false
}

variable "vpc_ip_range" {
  description = "CIDR of the VPC to create, for example 10.121.0.0/20 (only used when create_vpc is true)"
  type        = string
  default     = ""
}

variable "admin_ssh_cidrs" {
  description = "Who may reach SSH (port 22). Required, never empty: an empty list would lock everybody out."
  type        = list(string)
  validation {
    condition     = length(var.admin_ssh_cidrs) > 0 && !contains(var.admin_ssh_cidrs, "0.0.0.0/0")
    error_message = "admin_ssh_cidrs must list at least one address and must not contain 0.0.0.0/0."
  }
}

variable "public_http" {
  description = "Open port 80 to the whole internet (ACME and the public sites). false = only https_cidrs may reach 80."
  type        = bool
  default     = true
}

variable "https_cidrs" {
  description = "Who may reach port 443. Empty = no 443 rule."
  type        = list(string)
  default     = []
}

variable "extra_tcp_rules" {
  description = "Further inbound TCP ports, each with the CIDRs allowed. Example: { clover = { port = 8081, cidrs = [\"203.0.113.7/32\"] } }"
  type = map(object({
    port  = number
    cidrs = list(string)
  }))
  default = {}
}

# ---- storage ---------------------------------------------------------------------------------------------------------------
variable "create_pgdata_volume" {
  description = "Create the PostgreSQL data volume (deletion-protected). Its attachment is NEVER managed here: a human attaches it with doctl."
  type        = bool
  default     = false
}

variable "pgdata_size_gib" {
  description = "Size of the pgdata volume in GiB. No default: ADR-11 3.1 asks for max(20, 3 x the data set) on staging."
  type        = number
  default     = null
  validation {
    condition     = var.pgdata_size_gib == null || var.pgdata_size_gib >= 20
    error_message = "pgdata_size_gib must be at least 20."
  }
}

variable "buckets" {
  description = "Spaces buckets WITHOUT deletion protection (staging). name => settings."
  type = map(object({
    versioned       = bool
    noncurrent_days = number
  }))
  default = {}
}

variable "protected_buckets" {
  description = "Spaces buckets WITH prevent_destroy (production backups). name => settings."
  type = map(object({
    versioned       = bool
    noncurrent_days = number
  }))
  default = {}
}

# ---- monitoring ----------------------------------------------------------------------------------------------------------------
variable "alerts_enabled" {
  description = "Create the droplet alert policies (CPU, memory, disk, load). They need do-agent on the droplet (monitoring = true)."
  type        = bool
  default     = true
}

variable "alert_emails" {
  description = "E-mail addresses that receive alerts"
  type        = list(string)
  default     = []
}

variable "slack_channel" {
  description = "Slack channel for alerts (optional)"
  type        = string
  default     = ""
}

variable "slack_webhook_url" {
  description = "Slack incoming-webhook URL (a secret). Pass it from the environment: TF_VAR_slack_webhook_url. Never commit it."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cpu_threshold" {
  type    = number
  default = 80
}

variable "memory_threshold" {
  type    = number
  default = 85
}

variable "disk_threshold" {
  type    = number
  default = 80
}

variable "load5_threshold" {
  type    = number
  default = 4
}

variable "uptime_enabled" {
  description = "Create DigitalOcean uptime checks for uptime_targets"
  type        = bool
  default     = false
}

variable "uptime_targets" {
  description = "name => URL to probe from outside, for example { admin = \"http://203.0.113.9/\" }"
  type        = map(string)
  default     = {}
}

variable "uptime_regions" {
  type    = list(string)
  default = ["us_east", "eu_west"]
}
