# VERSIONS.md: the platform version matrix (machine-checked)

Source: ADR-08 section 3.1 (binding), amended by ADR-09, ADR-10 and ADR-11; runbook Appendix H.
`scripts/check-versions` compares every pin found in this repo with the `pins` block at the bottom of this file. A pin
that appears anywhere else with a different value fails CI (INFRA-CI-06). Changing a version needs an ADR-08 amendment.

Images are pinned **by digest** in compose files; the tag is recorded next to the digest. Digests are resolved when the
file that uses them is written (PI.3 to PI.7) with `docker buildx imagetools inspect <image>:<tag>`. Until then the
`Digest` column says `UNRESOLVED` and nothing may be deployed from it.

| # | Component | Pin | Digest | Notes |
|---|---|---|---|---|
| 1 | Host OS | Ubuntu 24.04 LTS, DO slug `ubuntu-24-04-x64` (24.04.5) | n/a | Terraform `image`, Ansible |
| 2 | Kernel | 24.04 kernel from the DO image (INFERRED 6.8 GA) | n/a | patched by unattended-upgrades and the patch window |
| 3 | Docker Engine | 29.x from download.docker.com (29.8.1 at ADR date) | n/a | Ansible pins major 29 |
| 4 | Compose | `docker-compose-plugin` v5.5.x (the v2 plugin CLI) | n/a | never the v1 `docker-compose` binary |
| 5 | Reverse proxy | nginx 1.30.5 (`nginx:1.30.5-alpine`), host network; `admin-web` uses `nginxinc/nginx-unprivileged:1.30-alpine` | UNRESOLVED | stable branch on a payment path |
| 6 | ACME client | certbot 5.8.x, snap, `certonly --webroot` | n/a | |
| 7 | Database | PostgreSQL 17, `postgres:17-trixie`, own container `odoosync-postgres` (ADR-11); 17.11 upstream | UNRESOLVED | one base digest is shared by CI, `images/postgres` and the E1' one-shots |
| 8 | Broker | RabbitMQ 4.3.x (`rabbitmq:4.3-management`, 4.3.6 at ADR date), without `transient_nonexcl_queues` | UNRESOLVED | a new minor only after INFRA-MQ-01 passes |
| 9 | Python | 3.12 (`python:3.12.14-slim-trixie`) | UNRESOLVED | omnisync Dockerfile |
| 10 | Image base distro | Debian 13 "trixie" slim | n/a | all images |
| 11 | Django | 5.2.x LTS (latest patch at H5; 5.2.17 at ADR date) | n/a | |
| 12 | App libraries | DRF 3.16.1, simplejwt 5.5.1 (never 5.5.0), djoser 2.3.4, drf-yasg 1.21.15, django-filter 25.1, cors 4.9.0; PyJWT pinned explicitly (2.15.x) | n/a | omnisync locks |
| 13 | DB driver | psycopg2-binary 2.9.10 through H5, then `psycopg[binary,pool]` 3.3.x at H6a | n/a | |
| 14 | Celery / kombu | celery 5.5.3, kombu 5.5.x | n/a | worker runs `--without-mingle --without-gossip` |
| 15 | WSGI server | gunicorn 26.2.0 (fallback 23.0.0) | n/a | |
| 16 | APM agent | newrelic 13.6.1, log forwarding off until D2 | n/a | |
| 17 | Node.js (build only) | 24 LTS (`node:24-trixie-slim`); fallback 22 only if the Vite 3 build fails on 24 | UNRESOLVED | admin Dockerfile, `.nvmrc`, CI |
| 18 | Package manager (admin) | yarn classic 1.x against the existing `yarn.lock` | n/a | |
| 19 | IaC | Terraform 1.16.x (`required_version = "~> 1.16"`), DigitalOcean provider `~> 2.102`, `.terraform.lock.hcl` committed | n/a | |
| 20 | Config management | ansible-core 2.21.x (Python >= 3.12); collections `community.docker`, `community.general`, `ansible.posix` pinned in `requirements.yml` | n/a | |
| 21 | Log shipper | Fluent Bit 5.0.x (`fluent/fluent-bit:5.0`), compose profile `logship` | UNRESOLVED | only after D2 |
| 22 | DO agents | `do-agent` via `monitoring = true`; droplet-agent as shipped | n/a | |
| 23 | Deploy agent | root `odoosync-pull` systemd timer; no CI runner on either droplet | n/a | |
| 24 | Image signing | cosign (Sigstore), keyless with GitHub OIDC | sha256 of the release binary: UNRESOLVED | version = latest release at C-08-06, pinned by checksum here |
| 25 | WAL-G (ADR-11 3.1) | version PROPOSED, pinned by version and sha256 like cosign | sha256: UNRESOLVED | |

## pins (read by scripts/check-versions)

```pins
UBUNTU_SLUG=ubuntu-24-04-x64
TERRAFORM_REQUIRED=~> 1.16
DO_PROVIDER=~> 2.102
NGINX_IMAGE=1.30.5
RABBITMQ_IMAGE=4.3
PYTHON_IMAGE=3.12.14
POSTGRES_BASE=17
NODE_IMAGE=24
FLUENT_BIT=5.0
```
