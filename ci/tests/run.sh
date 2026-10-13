#!/usr/bin/env bash
# Proves each CI check fails on bad input and passes on good input. Needs python3 and pyyaml.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; CI="$HERE/.."; pass=0; fail=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
w(){ mkdir -p "$(dirname "$T/$1")"; cat > "$T/$1"; }        # w <relpath> < content
expect(){  # expect <fail|pass> <label> <check script> [root]
  local want="$1" label="$2" script="$3" root="${4:-$T}"
  if python3 "$CI/$script" "$root" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "ok    $label"; else fail=$((fail+1)); echo "FAIL  $label (wanted $want, got $got)"; fi
}
clean(){ rm -rf "${T:?}"/*; }

# ---- terraform policy
clean; w terraform/a.tf <<'X'
resource "digitalocean_volume" "pgdata_prod" {
  name = "odoosync-pgdata-prod"
}
X
expect fail "pgdata volume without prevent_destroy" check_terraform_policy.py
clean; w terraform/a.tf <<'X'
resource "digitalocean_volume" "pgdata_prod" {
  name = "odoosync-pgdata-prod"
  lifecycle { prevent_destroy = true }
}
resource "digitalocean_volume" "pgdata_rehearsal" {
  name = "odoosync-pgdata-rehearsal"
}
X
expect pass "pgdata volume guarded, rehearsal volume unguarded" check_terraform_policy.py
clean; w terraform/d.tf <<'X'
resource "digitalocean_droplet" "droplet_rebuildable" {
  name = "x"
  lifecycle { ignore_changes = [user_data, image] }
}
X
expect fail "droplet missing ssh_keys in ignore_changes" check_terraform_policy.py
clean; w terraform/d.tf <<'X'
resource "digitalocean_droplet" "droplet_protected" {
  name = "x"
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [user_data, image, ssh_keys]
  }
}
X
expect pass "protected droplet fully guarded" check_terraform_policy.py
clean; w terraform/d.tf <<'X'
resource "digitalocean_droplet" "droplet_protected" {
  name = "x"
  lifecycle { ignore_changes = [user_data, image, ssh_keys] }
}
X
expect fail "droplet_protected without prevent_destroy" check_terraform_policy.py
clean; w terraform/db.tf <<'X'
resource "digitalocean_database_cluster" "pg" { name = "x" }
X
expect fail "managed database cluster" check_terraform_policy.py
clean; w terraform/b.tf <<'X'
resource "digitalocean_spaces_bucket" "backups" {
  name = "odoosync-prod-backups"
}
X
expect fail "production bucket without prevent_destroy" check_terraform_policy.py
clean; w terraform/v.tf <<'X'
resource "digitalocean_volume_attachment" "a" { volume_id = "v" }
X
expect fail "volume attachment in terraform" check_terraform_policy.py
clean; w terraform/ok.tf <<'X'
# resource "digitalocean_database_cluster" "commented" {
X
expect pass "commented-out database resource is ignored" check_terraform_policy.py

# ---- compose invariants
clean; w scripts/deploy <<'X'
docker compose -p omnisync up -d
X
expect fail "project-wide up -d" check_compose_invariants.py
clean; w scripts/deploy <<'X'
docker compose -p omnisync up -d --no-deps web
X
expect pass "up -d with a service name" check_compose_invariants.py
clean; w scripts/deploy <<'X'
docker compose stop -t 30 web
X
expect fail "literal -t 30" check_compose_invariants.py
clean; w scripts/deploy <<'X'
docker compose stop -t "$STOP_GRACE" web
X
expect pass "named STOP_GRACE symbol" check_compose_invariants.py

# ---- postgres
clean; w compose/compose.yml <<'X'
services:
  postgres:
    image: x
    ports: ["5432:5432"]
X
expect fail "postgres publishes a port" check_postgres.py
clean; w compose/compose.yml <<'X'
services:
  postgres:
    image: x
    expose: ["5432"]
X
expect pass "postgres has no ports key" check_postgres.py
clean; w terraform/fw.tf <<'X'
resource "digitalocean_firewall" "f" {
  inbound_rule { port_range = "5432" }
}
X
expect fail "5432 in a firewall definition" check_postgres.py
clean; w compose/postgres/pg_hba.conf <<'X'
local all all trust
host all all 0.0.0.0/0 reject
X
w compose/postgres/postgresql.conf <<'X'
password_encryption = scram-sha-256
X
expect fail "pg_hba with trust" check_postgres.py
clean; w compose/postgres/pg_hba.conf <<'X'
host omnisync_connector omnisync_app 172.30.2.0/24 scram-sha-256
host all all 0.0.0.0/0 reject
X
w compose/postgres/postgresql.conf <<'X'
password_encryption = scram-sha-256
X
expect pass "good pg_hba and postgresql.conf" check_postgres.py
clean; w compose/postgres/pg_hba.conf <<'X'
host all all 0.0.0.0/0 reject
host omnisync_connector omnisync_app 172.30.2.0/24 scram-sha-256
X
w compose/postgres/postgresql.conf <<'X'
password_encryption = scram-sha-256
X
expect fail "reject line is not last" check_postgres.py
clean; w compose/postgres/pg_hba.conf <<'X'
host all postgres 172.30.2.0/24 scram-sha-256
host all all 0.0.0.0/0 reject
X
w compose/postgres/postgresql.conf <<'X'
password_encryption = scram-sha-256
X
expect fail "host line for the postgres role" check_postgres.py
clean; w compose/postgres/pg_hba.conf <<'X'
host all all 0.0.0.0/0 reject
X
w compose/postgres/postgresql.conf <<'X'
password_encryption = md5
X
expect fail "password_encryption not scram" check_postgres.py
clean; A=$(printf 'a%.0s' $(seq 64)); B=$(printf 'b%.0s' $(seq 64))
w images/postgres/Dockerfile <<X
FROM postgres:17-trixie@sha256:$A
X
w .github/workflows/ci.yml <<X
image: postgres:17-trixie@sha256:$B
X
expect fail "two different postgres base digests" check_postgres.py
clean; w images/postgres/Dockerfile <<X
FROM postgres:17-trixie@sha256:$A
X
w .github/workflows/ci.yml <<X
image: postgres:17-trixie@sha256:$A
X
expect pass "one postgres base digest everywhere" check_postgres.py

# ---- windows
clean; w config/windows.yml <<'X'
windows:
  pgbackup:  {day: daily, start: "02:00", minutes: 60}
  walg_base: {day: sun,   start: "02:30", minutes: 120}
X
expect fail "backup and base backup overlap" check_windows.py
clean; w config/windows.yml <<'X'
windows:
  pgbackup:  {day: daily, start: "02:00", minutes: 60}
  walg_base: {day: sun,   start: "03:00", minutes: 120}
  patch:     {day: wed,   start: "04:00", minutes: 120}
X
expect pass "non-overlapping windows" check_windows.py

# ---- versions
clean; w VERSIONS.md <<'X'
```pins
NGINX_IMAGE=1.30.5
TERRAFORM_REQUIRED=~> 1.16
```
X
w compose/x.yml <<'X'
image: nginx:1.28.0-alpine
X
if python3 "$CI/../scripts/check-versions" "$T" >/dev/null 2>&1; then r=pass; else r=fail; fi
[ "$r" = fail ] && { pass=$((pass+1)); echo "ok    version mismatch is caught"; } || { fail=$((fail+1)); echo "FAIL  version mismatch is caught"; }
w compose/x.yml <<'X'
image: nginx:1.30.5-alpine
X
if python3 "$CI/../scripts/check-versions" "$T" >/dev/null 2>&1; then r=pass; else r=fail; fi
[ "$r" = pass ] && { pass=$((pass+1)); echo "ok    matching version passes"; } || { fail=$((fail+1)); echo "FAIL  matching version passes"; }
w terraform/m.tf <<'X'
terraform { required_version = "~> 1.15" }
X
if python3 "$CI/../scripts/check-versions" "$T" >/dev/null 2>&1; then r=pass; else r=fail; fi
[ "$r" = fail ] && { pass=$((pass+1)); echo "ok    wrong terraform required_version is caught"; } || { fail=$((fail+1)); echo "FAIL  wrong terraform required_version is caught"; }

echo "ci checks self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
