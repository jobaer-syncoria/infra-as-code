# Rebuild the staging server from scratch

Goal: turn a freshly rebuilt Ubuntu 24.04 droplet into the full staging stack with **one command from your PC**.
Everything below is what you do by hand. Nothing else is manual.

Status: the roles were checked with a syntax check, a dry run on the current staging droplet, and a real run of the
code step. **A full run from a fresh server has not happened yet**, so expect to fix a few things on the first try.
Running it again is safe: every step checks before it changes anything.

## What you get
| What | Where |
|---|---|
| omnisync admin site | `http://<server-ip>/` |
| Clover Cloud | `http://<server-ip>:8081/` |
| 9 containers | postgres, rabbit, web, worker, admin, edge (nginx), mongo, clover-node, sc-bridge |
| Server hardening | key-only SSH as `syncoria-dev`, no root login, ufw, fail2ban, Docker log rotation, unattended security upgrades |

The stack is the same one that runs on staging today: the omnisync image from branch `ci/omnisync-image-contract`
(Python 3.12, Django 5.2, PostgreSQL 17), the admin image from `ci/admin-release`, and clover-node from
`fix/ns-outbound-and-broken` (Node 16, Mongo 6).

## Before you start
- **A rebuild wipes the whole disk.** That includes the database, the Clover configuration (merchant `P32FN21KQH431`), the
  admin logins and the dump files in `~/apps/stack/backup/`. A new stack starts empty. If you want anything from the
  old server (for example the `pg17.dump` or `mongo-clover.archive`), copy it to your PC first:
  ```bash
  scp -r syncoria-dev@<server-ip>:apps/stack/backup ~/staging-backup
  ```
- You have the **three app repos** on your PC at the branches above (`scripts/make-bundles.sh` checks this and stops with
  a clear message if one is missing).
- Your SSH key is added to your DigitalOcean account.

## Steps
### 1. Rebuild the droplet (DigitalOcean console, about 3 minutes)
Droplet, then Destroy, then **Rebuild Droplet**. Choose **Ubuntu 24.04 (LTS) x64** and select **your SSH key**. Wait until
the droplet is "On". The IP address stays the same.

### 2. Run the rebuild (your PC)
```bash
/home/zubayer/infra-as-code/rebuild-staging.sh <server-ip> [path-to-your-private-key]
```
It does four things by itself: forgets the old host key, packs the three app repos into bundles, copies the bundles and
this repo to the server, and starts the Ansible run on the server. The first run takes about **15 to 25 minutes**
(most of it is building the images).

### 3. Type two passwords when asked
Near the start it asks for a password for the **omnisync admin** (user `stgadmin`) and one for the **Clover Cloud admin**
(user `admin`). Press Enter to skip either; typing shows nothing. They are used once and are not saved anywhere else.

### 4. Check the result
The run ends with a summary of the URLs and the container list. Then:
- Open `http://<server-ip>/` and log in as `stgadmin`.
- Open `http://<server-ip>:8081/` and log in as `admin`.
- From now on log in to the server as `syncoria-dev` (root login is switched off):
  `ssh syncoria-dev@<server-ip>`.

### 5. Things only a person can do afterwards
- Add the Clover merchant configuration in the Clover Cloud UI (Users, then the user's config). The real Clover sandbox
  app id and app secret come from the Clover developer dashboard.
- Restore old data only if you need it (the dumps from "Before you start").

## If something fails
Read the last error in the output. Fix it, then run the same command again.

| Symptom | Likely cause and fix |
|---|---|
| `Permission denied (publickey)` at step 2 | The droplet was rebuilt without your key. Rebuild again and select the key, or pass the key path as the second argument. |
| `branch ... not found` or `not a git repo` | An app repo or branch is missing on your PC. Override with `OMNISYNC=... ADMIN=... CLOVER=...` or check the branch names in `ansible/inventories/staging/group_vars/all.yml`. |
| `docker-ce=5:29.*` not found | Docker's 29 line is not in the apt repository yet. Set `docker_version_pin` in `group_vars/all.yml` to a version that exists (`apt-cache madison docker-ce` on the server). |
| An image build is killed (`exit code 137`) | Out of memory. The swap file is created first; if it still happens, resize the droplet to 4 GB RAM or more. |
| `SSH hardening was rolled back` | sshd rejected the new settings. Nothing is locked out: the old settings are back. Read the error above it. |
| `deploy_user ... has no SSH key` | The droplet was rebuilt without an SSH key. Add yours to `/root/.ssh/authorized_keys` on the server and rerun. |
| The run stops while building | Rerun. Finished steps are skipped. |

To rerun on the server only (after the first copy): `ssh root@<server-ip>` (first run) or `ssh syncoria-dev@<server-ip>`
then `sudo bash /root/odoosync-infra/scripts/rebuild-staging.sh`.

## Good to know
- Secrets (database, broker, Mongo, Django, Clover token) are generated **on the server** the first time and are stored
  only in the env files under `~/apps/stack/` (mode 0600). They are not in this repo and not printed. A rerun never
  replaces them.
- Port 8081 is open to everyone (staging only). Docker-published ports bypass ufw, so the DigitalOcean Cloud Firewall
  is the real control; it comes with the Terraform step. Use throwaway passwords.
- The sites are plain HTTP. Do not enter real secrets.
- To change the stack, edit `ansible/roles/stack/templates/docker-compose.yml.j2`, then rerun.
- This is the staging recipe only. Production has its own rules (runbook Phase A, ADR-09) and is rebuilt later.
