# PostgreSQL data volume (ADR-11 3.1). Deletion-protected. It is created WITHOUT a filesystem and is NEVER attached here:
# a human attaches it with doctl, so a plan can never detach a live database. See the README.
resource "digitalocean_volume" "pgdata" {
  count       = var.create_pgdata_volume ? 1 : 0
  name        = "${local.prefix}-pgdata"
  region      = var.region
  size        = var.pgdata_size_gib
  description = "PostgreSQL data (${var.environment}). Attached by a human with doctl, never by Terraform."

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.pgdata_size_gib != null
      error_message = "pgdata_size_gib must be set when create_pgdata_volume is true."
    }
  }
}

# Backup buckets (ADR-11 3.4): private, versioned, noncurrent versions expire. Two resources, because prevent_destroy cannot
# be switched per bucket: 'protected' (production) and 'open' (staging, may be torn down with the environment).
resource "digitalocean_spaces_bucket" "protected" {
  for_each = var.protected_buckets
  name     = each.key
  region   = var.region
  acl      = "private"

  versioning {
    enabled = each.value.versioned
  }

  lifecycle_rule {
    id      = "expire-noncurrent"
    enabled = each.value.versioned
    noncurrent_version_expiration {
      days = each.value.noncurrent_days
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_spaces_bucket" "open" {
  for_each = var.buckets
  name     = each.key
  region   = var.region
  acl      = "private"

  versioning {
    enabled = each.value.versioned
  }

  lifecycle_rule {
    id      = "expire-noncurrent"
    enabled = each.value.versioned
    noncurrent_version_expiration {
      days = each.value.noncurrent_days
    }
  }
}
