# Bootstrap (PI.1 commands, run by a human)

Claude Code does not run any command on this page. Each needs an account owner's credentials.

1. **Repo.** A GitHub org admin creates the private repo (default branch `production`), enables branch protection on
   `production` (PR, passing `ci`, one approval) and grants the release-approvers team write access.
2. **State bucket.** In the DigitalOcean console create the Space `odoosync-tfstate` (tor1), versioning on, private.
   Create a Spaces key scoped to that bucket and keep it in the password manager.
3. **Tokens.** The infra owner creates a custom-scoped DigitalOcean API token with 90-day expiry. It is held in the owner's
   shell only, as `DIGITALOCEAN_TOKEN`. Never commit it, and never put it in tfvars, CI or a droplet.
4. **First run (after PI.3 exists).**
   ```bash
   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...     # bucket-scoped Spaces key, for the s3 backend
   export SPACES_ACCESS_KEY_ID=... SPACES_SECRET_ACCESS_KEY=... # same key, for the provider
   export DIGITALOCEAN_TOKEN=...
   cd terraform/envs/staging && terraform init && terraform plan   # paste the plan into the PR
   ```
5. **Review.** Every plan is pasted into its PR and read by a second person before any apply.
