terraform {
  required_version = "~> 1.16"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.102"
    }
  }
}

# The provider reads its credentials from the ENVIRONMENT, never from a file in this repo:
#   DIGITALOCEAN_TOKEN                               (API token, custom scope, 90-day expiry)
#   SPACES_ACCESS_KEY_ID / SPACES_SECRET_ACCESS_KEY  (only for the Spaces buckets)
provider "digitalocean" {}
