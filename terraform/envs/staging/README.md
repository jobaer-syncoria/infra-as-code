# Staging environment (Terraform)

Firewall, project, tags, optional pgdata volume and backup bucket, alerts and uptime checks for the staging droplet.
**The droplet is not managed here**; it is looked up by name.

## Run it (you run these, with your own credentials; Claude Code never does)
```bash
cd terraform/envs/staging
cp staging.auto.tfvars.example staging.auto.tfvars     # edit: region, droplet_name, your public IPs
export DIGITALOCEAN_TOKEN=...                          # API token, custom scope, 90-day expiry. Never in a file.
# State: a private versioned Space (backend.tf) ...
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... # Spaces key, only for the state bucket
terraform init
# ... or, for a playground without a bucket: mv backend.tf backend.tf.disabled && terraform init
terraform plan -out=tf.plan                            # read it; paste it into the PR; a second person reviews
terraform apply tf.plan
```
Buckets need `export SPACES_ACCESS_KEY_ID=... SPACES_SECRET_ACCESS_KEY=...` as well.

## Before you apply
- Put **your own public IP** in `admin_ssh_cidrs` or you lock yourself out of SSH (the Cloud Firewall wins over ufw).
- With `clover_ui_cidrs` and `grafana_cidrs` empty, ports 8081 and 3001 are **closed** in the Cloud Firewall. Docker-published ports
  are only reachable if this firewall allows them, so list your IPs there.
- The first plan must show only creations (firewall, tags, project, ...) and **no change or destroy on the droplet**.

## Check without any account
```bash
terraform init -backend=false && terraform validate     # and: terraform fmt -check -recursive ../..
```
