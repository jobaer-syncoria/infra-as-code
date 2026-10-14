# State in a DigitalOcean Space (runbook PI.3). Create the bucket once by hand, private and versioned, then:
#   export AWS_ACCESS_KEY_ID=<spaces key id>  AWS_SECRET_ACCESS_KEY=<spaces secret>
#   terraform init
# For a quick playground WITHOUT a state bucket, rename this file to backend.tf.disabled: Terraform then keeps a local
# terraform.tfstate (git-ignored; it holds resource ids, so do not share it).
terraform {
  backend "s3" {
    bucket                      = "odoosync-tfstate"
    key                         = "staging/terraform.tfstate"
    region                      = "us-east-1"
    endpoints                   = { s3 = "https://tor1.digitaloceanspaces.com" }
    use_lockfile                = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}
