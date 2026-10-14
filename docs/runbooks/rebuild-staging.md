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

### 2b. Restore a database backup (optional)
To start from an existing omnisync database instead of an empty one, pass the dump file:
```bash
DB_DUMP=/home/zubayer/staging-backup/omnisync-20261013-1827.dump /home/zubayer/infra-as-code/rebuild-staging.sh <server-ip> [key]
```
The script uploads it, and Ansible restores it into PostgreSQL **before** the web container starts. The web container then
runs `migrate` on top, so a dump from an older code version is brought up to date. Works for `pg_dump -Fc` (custom) and
plain SQL dumps. A rerun does not restore again (the file `~/apps/stack/.db-restored` marks it done; delete that file to
restore again, which **overwrites** the database). When the dump already contains your admin users, the passwords you type
at step 3 for existing users are ignored (the user is kept as restored).

**Make a staging backup any time:**
```bash
ssh syncoria-dev@<server-ip> 'cd ~/apps/stack && docker compose -p omnisync-stg exec -T postgres pg_dump -U omnisync -Fc omnisync' > omnisync-$(date +%Y%m%d-%H%M).dump
```
Dumps hold real data and password hashes: keep them out of git (`*.dump` is in `.gitignore`) and out of chat.

**Go-live:** use the production dump instead (`DB_DUMP=<production dump>`). Production has its own procedure (runbook
Phase 7, ADR-03 and ADR-09: sealed dump from the transfer volume, Django upgrade hops from 3.2 to 5.2). A raw restore of an
old-version database into the new code is **not** the approved path until that is rehearsed on staging with a copy of
the real data.

### 2b2. Restore the Clover Mongo (local mongo container only)
```bash
MONGO_DUMP=/home/zubayer/staging-backup/mongo-clover-20261014-0045.archive /home/zubayer/infra-as-code/rebuild-staging.sh <server-ip> [key]
```
Restores the archive (`mongodump --archive --gzip`) into the local mongo container **before** clover-node starts, replacing the
`clover` database. The Clover users, merchant configs (with their app secrets), device lines and auth policies come back, so you
do not re-enter anything and no Clover admin prompt appears. A rerun does not restore again (marker `~/apps/stack/.mongo-restored`;
delete it to restore again). You can pass both `DB_DUMP` and `MONGO_DUMP` in one run.
**Not used with a cloud Mongo** (see 2c): then the data already lives in Atlas and nothing is restored or migrated.

**Make a Clover backup any time:**
```bash
ssh syncoria-dev@<server-ip> 'cd ~/apps/stack && docker compose -p omnisync-stg exec -T mongo sh -c "mongodump --quiet --uri=\"mongodb://\$MONGO_INITDB_ROOT_USERNAME:\$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/clover?authSource=admin\" --archive --gzip"' > clover-$(date +%Y%m%d-%H%M).archive
```

### 2c. Use a cloud Mongo (Atlas) for Clover instead of the local container (optional; this is how go-live works)
By default Clover uses a Mongo container on the server (staging). To point it at a cloud Mongo, such as an Atlas staging
cluster or, at go-live, the production Atlas:
```bash
read -rs CLOVER_DB_URL; export CLOVER_DB_URL        # paste the mongodb+srv://... URL, nothing is shown
/home/zubayer/infra-as-code/rebuild-staging.sh <server-ip> [key]
```
The URL is sent over SSH into a root-only file on the server (`/opt/odoosync-secrets/clover_db_url`), never printed, never
in git. When that file exists, **no mongo container is started** and clover-node's `DB_URL` is the URL from the file.
To go back to the local container, delete that file and rerun.

clover-node refuses to start if the database host equals the production Atlas host while the environment is not
`production` (and the reverse). So at go-live pass both settings (the host name only, no password):
```bash
ANSIBLE_ARGS='-e clover_deploy_env=production -e clover_production_db_host=<production-atlas-host>' ./rebuild-staging.sh ...
```
and set `clover_production_db_host` in staging too, so a mistake there is refused. Atlas must also allow the server's IP in
its access list (the Atlas owner does that; the runbook keeps today's production IP). Never point a staging server at the
production Atlas without the Atlas owner's approval.

### 3. Admin passwords (only when there is nothing to restore)
With `DB_DUMP` the omnisync users come from the dump, and with `CLOVER_DB_URL` Clover's users live in the cloud Mongo, so
the script asks for neither. Without them Ansible asks for an omnisync admin password (user `stgadmin`) and a Clover Cloud
admin password (user `admin`); Enter skips one, and typing shows nothing. They are used once and are not saved elsewhere.

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
