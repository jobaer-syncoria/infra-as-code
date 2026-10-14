variable "region" {
  type = string
}

variable "droplet_name" {
  description = "Name of the existing staging droplet (looked up, never created)"
  type        = string
  default     = ""
}

variable "admin_ssh_cidrs" {
  type = list(string)
}

variable "public_http" {
  type    = bool
  default = true
}

variable "https_cidrs" {
  type    = list(string)
  default = []
}

variable "clover_ui_cidrs" {
  description = "Who may reach Clover Cloud on port 8081. Empty = nobody (closes the port in the Cloud Firewall)."
  type        = list(string)
  default     = []
}

variable "grafana_cidrs" {
  description = "Who may reach Grafana on port 3001. Empty = nobody."
  type        = list(string)
  default     = []
}

variable "create_pgdata_volume" {
  type    = bool
  default = false
}

variable "pgdata_size_gib" {
  type    = number
  default = null
}

variable "walg_bucket_name" {
  description = "Spaces bucket for WAL-G backups of the staging PostgreSQL. Bucket names are unique per region across all customers. Empty = none."
  type        = string
  default     = ""
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "slack_channel" {
  type    = string
  default = ""
}

variable "slack_webhook_url" {
  type      = string
  default   = ""
  sensitive = true
}

variable "uptime_enabled" {
  type    = bool
  default = false
}

variable "uptime_targets" {
  type    = map(string)
  default = {}
}
