# Deploy to staging with odoosync-deploy

Status: the tools, the pull timer, the Ansible role and the release compose file are built and tested **in containers**. They have **never been run on the
staging server**, and no image has been deployed through them yet. Read "What is not done" before you rely on this.

## How a release reaches staging
1. A merge produces a signed image: the omnisync branch `staging-release` runs the workflow *Release image (staging)* and publishes
   `ghcr.io/syncoria/omnisync-staging@sha256:<digest>`, signed as `release-staging.yml@refs/heads/staging-release`.
2. A **release approver** signs a git tag in the infra repo (`release/YYYYMMDD-N`) on the `production` branch.
3. On the server, as root, one command applies one service:
   ```bash
   sudo odoosync-deploy request --env /etc/odoosync/env --service web --digest sha256:<digest> --ref release/20261015-1
   ```
   The tool refuses unless: the tag is signed by an approver key and reachable from `production`; the image digest carries a valid
   signature from the trusted workflow; `nginx/serving_values.json` equals the file inside the image; PostgreSQL is 14 or newer; no freeze is set.
   It then pulls the image by digest, recreates **only** that service, waits until it is healthy, and **rolls back by itself** if it is not.

## One-time setup
1. **Merge the infra pull requests into `production`** of the infra repo. The tag must be reachable from `production`, and the server reads
   `compose/compose.yml` and `nginx/serving_values.json` from the tagged commit.
2. **An approver key.** On the approver's PC, an SSH key used only for signing (a private key never leaves that PC):
   `ssh-keygen -t ed25519 -f ~/.ssh/odoosync-release -C approver-name`. The `.pub` file is what the server trusts.
3. **Install the tools on the server** (the rebuild does it when it is given the public key):
   ```bash
   APPROVER_KEYS=~/.ssh/odoosync-release.pub SSH_USER=syncoria-dev ./rebuild-staging.sh <server-ip> <ssh-key>
   ```
   Without `APPROVER_KEYS` the role skips itself with a clear message, so a rebuild never fails because of it.
4. **A registry read token on the server** (a person does this, the token is never in git or in a file in this repo):
   a GitHub token with only `read:packages`, then on the server `read -rs T; printf %s "$T" | sudo docker login ghcr.io -u <github-user> --password-stdin; unset T`.
   Without it the server cannot pull a private image.
5. If the infra repo is private, give the server a **read-only deploy key** and set `infra_deploy_key_file` (the stand-in repo is public today).

## Make a release
On the approver's PC, in a clone of the infra repo:
```bash
git switch production && git pull
scripts/make-release-tag.sh release/20261015-1 ~/.ssh/odoosync-release   # signs, verifies, asks "yes", pushes
```
On the server, refresh the clone and apply (a pull timer will do the refresh later):
```bash
sudo git -C /srv/odoosync/infra.git fetch --prune origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
sudo odoosync-deploy request --env /etc/odoosync/env --service web --digest sha256:<digest> --ref release/20261015-1
```
Try a dry run first: add `--check-only` (runs every guard, starts nothing).

## Automatic deploys: the pull timer (staging)
On staging the role also installs `odoosync-pull` and a systemd timer that runs it **every 2 minutes**. Each run:
1. fetches the infra repo; takes the newest `release/*` tag that is **signed by an approver and reachable from `production`**
   (anything else is ignored and logged as `pull_ignored_tag <tag> unverified|not_on_production`);
2. asks the registry which digest the moving tag `staging` points to, for each service (`worker` first, then `web`);
3. for each service whose digest differs from the last successful release, runs `odoosync-deploy request` (all guards, then the safe recreate with
   automatic rollback). It stops at the first failure; the next run retries. It does nothing while `DEPLOY_FREEZE` is set, and skips quietly when a person is deploying.
Watch it: `journalctl -u odoosync-pull -f` or `systemctl list-timers odoosync-pull.timer`. Stop it: `sudo systemctl disable --now odoosync-pull.timer`
(or `odoosync-deploy flag set DEPLOY_FREEZE 1`). Log lines: `pull_ok`, `pull_noop`, `pull_apply`, `pull_failed`, `pull_frozen`, `pull_busy`, `pull_no_valid_tag`,
`pull_registry_failed`, `pull_fetch_failed`. The timer needs the registry login from step 4 of the setup, or it logs `pull_registry_failed`.
**Production has the timer switched off** (`deploy_pull_enabled: false`) and would read digests from the signed `releases/production.json`, never from the registry.

## Roll back, stop, freeze
```bash
sudo odoosync-deploy rollback --service web          # previous good release, through every guard again
sudo odoosync-deploy stop web
sudo odoosync-deploy flag set DEPLOY_FREEZE 1        # blocks every deploy (also: flag unset DEPLOY_FREEZE)
```
Every deploy is logged in `/srv/odoosync/state/releases.jsonl` (ok, failed, rolled_back, stopped) with the operator.

## What is not done
- `odoosync-promote` (the approver's tool that writes `releases/production.json` and opens the PR) and `odoosync-verify` are **not built**; the pull timer is built but has never run on the server.
- **Only `web` and `worker`** are in the release compose file. The other services (postgres, rabbit, admin, edge, mongo, clover-node, monitoring) stay as
  the Ansible stack role defines them. Until the admin and Clover images are published, they stay locally built.
- **Zero-drop blue/green is not built.** On staging `web` is simply recreated (a brief gap). **Production refuses** the payment-path services
  (`web`, `web-terminal`, `edge`, `rabbitmq`, `postgres`, `clover-node`) until blue/green exists.
- `web` runs `migrate` when it starts, as in the Ansible stack. A destructive migration is blocked earlier by the omnisync CI check, not by this tool.
- The signature of the staging image was verified **inside GitHub's run**. A cosign v3 verification from the server has not been done yet (it needs the read token above).
- Never run on the staging server. The first real run is a test: expect to fix something.
