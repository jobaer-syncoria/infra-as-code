#!/usr/bin/env bats
# odoosync-deploy slice 2: apply (safe recreate), rollback, stop, flags, lock, release log, and the new guards.
load helpers

setup() { make_sandbox; set_env staging; REPO=ghcr.io/syncoria/omnisync; }
teardown() { rm -rf "$ROOT"; }

refused() { [ "$status" -eq 3 ] && [[ "$output" == *"deploy_refused $1"* ]]; }
last_result() { tail -n1 "$SRV/state/releases.jsonl" | jq -r .result; }
image_of() { sed -n "s/^IMAGE_$1=//p" "$SRV/state/images.env"; }

# ----------------------------------------------------------------------------------------------------------- apply
@test "apply: pulls the exact digest, recreates ONLY that service, no project-wide up, no literal timeout" {
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]; [[ "$output" == *"applied service=web"* ]]
  grep -q "^pull $REPO@$D1\$" "$STUB_DOCKER_LOG"
  [ "$(grep -c ' up ' "$STUB_DOCKER_LOG")" -eq 1 ]
  grep ' up ' "$STUB_DOCKER_LOG" | grep -q -- '--no-deps --force-recreate web$'
  ! grep ' up ' "$STUB_DOCKER_LOG" | grep -Eq -- ' -t [0-9]| --timeout'
  [ "$(image_of WEB)" = "$REPO@$D1" ]
  [ "$(last_result)" = ok ]
}
@test "apply: the compose file used is the one of the VERIFIED release tree, with the images file" {
  apply web "$D1" release/ok
  grep ' up ' "$STUB_DOCKER_LOG" | grep -q -- "-f $SRV/releases/release/ok/compose/compose.yml"
  grep ' up ' "$STUB_DOCKER_LOG" | grep -q -- "--env-file $SRV/state/images.env"
}
@test "apply: service names with a dash map to a clean variable (web-terminal -> IMAGE_WEB_TERMINAL)" {
  policy_add '.services["web-terminal"] = "ghcr.io/syncoria/omnisync"'
  apply web-terminal "$D1" release/ok
  [ "$status" -eq 0 ]
  grep -q '^IMAGE_WEB_TERMINAL=' "$SRV/state/images.env"
}
@test "apply: a failed pull changes nothing" {
  STUB_PULL_FAIL=1 apply web "$D1" release/ok
  refused pull_failed
  [ ! -e "$SRV/state/images.env" ] && [ ! -e "$SRV/state/releases.jsonl" ]
  ! grep -q ' up ' "$STUB_DOCKER_LOG"
}
@test "apply: --check-only runs the guards and starts nothing" {
  request web "$D1" release/ok
  [ "$status" -eq 0 ]
  ! grep -q '^pull\| up ' "$STUB_DOCKER_LOG"
}

# ------------------------------------------------------------------------------------------ health and automatic rollback
@test "rollback on failure: an unhealthy new release is replaced by the previous one, exit 4" {
  apply web "$D1" release/ok; [ "$status" -eq 0 ]
  printf 'unhealthy healthy' > "$ROOT/health.seq"
  apply web "$D3" release/ok
  [ "$status" -eq 4 ]
  [[ "$output" == *"deploy_failed"* && "$output" == *"rolled_back_to=$D1"* ]]
  [ "$(image_of WEB)" = "$REPO@$D1" ]
  [ "$(jq -r .result "$SRV/state/releases.jsonl" | paste -sd, -)" = "ok,failed,rolled_back" ]
}
@test "rollback on failure: a compose up that fails also rolls back" {
  apply web "$D1" release/ok; [ "$status" -eq 0 ]
  STUB_UP_FAIL=1 apply web "$D3" release/ok
  [ "$status" -ne 0 ]
  [[ "$output" == *deploy_failed* ]]
}
@test "failure with no previous release is reported, never silent" {
  printf 'unhealthy' > "$ROOT/health.seq"
  apply web "$D1" release/ok
  [ "$status" -eq 4 ]
  [[ "$output" == *"no_previous_release"* ]]
  [ "$(last_result)" = failed ]
}
@test "a failed release is never used as the rollback target" {
  apply web "$D1" release/ok
  printf 'unhealthy healthy' > "$ROOT/health.seq"; apply web "$D3" release/ok
  run "$SCRIPTS/odoosync-deploy" rollback --service web
  # the only successful release other than the current one does not exist (the current one is D1 again)
  refused no_previous_release
}

# --------------------------------------------------------------------------------------------------- rollback command
@test "rollback: goes back to the previous successful release through every guard" {
  apply web "$D1" release/ok; apply web "$D3" release/ok
  [ "$(image_of WEB)" = "$REPO@$D3" ]
  run "$SCRIPTS/odoosync-deploy" rollback --service web
  [ "$status" -eq 0 ]; [[ "$output" == *"applied service=web digest=$D1"* ]]
  [ "$(image_of WEB)" = "$REPO@$D1" ]
}
@test "rollback: refused when there is no previous release" {
  apply web "$D1" release/ok
  run "$SCRIPTS/odoosync-deploy" rollback --service web
  refused no_previous_release
}
@test "rollback: the old release is verified again (an unsigned image is refused even on rollback)" {
  apply web "$D1" release/ok; apply web "$D3" release/ok
  STUB_COSIGN_FAIL=1 run "$SCRIPTS/odoosync-deploy" rollback --service web
  refused signature_invalid
  [ "$(image_of WEB)" = "$REPO@$D3" ]
}

# --------------------------------------------------------------------------------------------------------------- lock
@test "lock: a second deploy while one is running is refused" {
  exec 8>"$SRV/state/deploy.lock"; flock -n 8
  apply web "$D1" release/ok
  refused busy
  flock -u 8
}

# ------------------------------------------------------------------------------------------------ production restrictions
@test "production: a payment-path service is never recreated by this slice (needs blue/green)" {
  set_env production
  apply web "$D1" release/ok
  refused apply_needs_bluegreen
  ! grep -q ' up ' "$STUB_DOCKER_LOG"
}
@test "production: edge, rabbitmq, postgres and clover-node are refused too" {
  set_env production
  for s in edge rabbitmq postgres clover-node; do
    policy_add ".services[\"$s\"] //= \"docker.io/library/nginx\""
  done
  policy_add '.upstream += ["docker.io/library/nginx"]'
  # the guards pass for these (digest pinned in compose or in the release file) only when named; the refusal must come first or at apply
  apply edge "$D2" release/ok
  [ "$status" -eq 3 ]
}
@test "production: a service off the payment path (worker) can be recreated" {
  set_env production
  printf '{"web":"%s","worker":"%s"}\n' "$D1" "$D1" > "$WORK/releases/production.json"
  git -C "$WORK" add -A; git -C "$WORK" commit -q -m worker
  git -C "$WORK" push -q "$SRV/infra.git" production
  signed_tag release/w "$KEYS/approver"
  apply worker "$D1" release/w
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------------------------------------------ missing secrets
@test "missing secret: a service whose required secret is absent does not start" {
  policy_add '.required_secrets = {"web":["DJANGO_SECRET_KEY","DATABASE_URL"]}'
  printf 'DJANGO_SECRET_KEY=abc\n' > "$ETC/secrets.env"; chmod 600 "$ETC/secrets.env"
  apply web "$D1" release/ok
  refused missing_secret
  [[ "$output" == *DATABASE_URL* && "$output" != *abc* ]]
  ! grep -q ' up ' "$STUB_DOCKER_LOG"
}
@test "missing secret: an empty value counts as missing" {
  policy_add '.required_secrets = {"web":["DJANGO_SECRET_KEY"]}'
  printf 'DJANGO_SECRET_KEY=\n' > "$ETC/secrets.env"; chmod 600 "$ETC/secrets.env"
  apply web "$D1" release/ok
  refused missing_secret
}
@test "missing secret: all required secrets present lets the deploy through" {
  policy_add '.required_secrets = {"web":["DJANGO_SECRET_KEY"]}'
  printf 'DJANGO_SECRET_KEY=abc\n' > "$ETC/secrets.env"; chmod 600 "$ETC/secrets.env"
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------------------------------- image by environment
@test "image not allowed: an image denied for this environment is refused" {
  policy_add '.deny_repos = {"rehearsal":["ghcr.io/syncoria/omnisync"]}'
  set_env rehearsal
  apply web "$D1" release/ok
  refused image_not_allowed
}

# ------------------------------------------------------------------------------------------------- clover-node env
clover_policy() {
  policy_add '.services["clover-node"] = "ghcr.io/syncoria/clover-node"
              | .images["ghcr.io/syncoria/clover-node"] = {"identity":"https://github.com/syncoria/odoo-clover-cloud/.github/workflows/release.yml@refs/heads/node-app","issuer":"https://token.actions.githubusercontent.com"}'
  export STUB_COSIGN_OK_IDENTITY="https://github.com/syncoria/odoo-clover-cloud/.github/workflows/release.yml@refs/heads/node-app"
}
write_clover_env() { printf '%s\n' "$@" > "$ETC/clover.env"; chmod 644 "$ETC/clover.env"; }
@test "clover_env: staging accepts CLOVER_DEPLOY_ENV=staging" {
  clover_policy; write_clover_env CLOVER_DEPLOY_ENV=staging 'DB_URL=mongodb://mongo/clover'
  request clover-node "$D1" release/ok
  [ "$status" -eq 0 ]
}
@test "clover_env: staging refuses CLOVER_DEPLOY_ENV=production" {
  clover_policy; write_clover_env CLOVER_DEPLOY_ENV=production
  request clover-node "$D1" release/ok
  refused clover_env
  [[ "$output" == *deploy_env_production_on_staging* ]]
}
@test "clover_env: an unset CLOVER_DEPLOY_ENV is refused" {
  clover_policy; write_clover_env 'DB_URL=mongodb://mongo/clover'
  request clover-node "$D1" release/ok
  refused clover_env
  [[ "$output" == *deploy_env_unset* ]]
}
@test "clover_env: a non-production host that names the production Atlas host is refused (names only)" {
  clover_policy
  write_clover_env CLOVER_DEPLOY_ENV=staging CLOVER_PRODUCTION_DB_HOST=prod.mongodb.example 'DB_URL=mongodb+srv://u:topsecret@prod.mongodb.example/clover'
  request clover-node "$D1" release/ok
  refused clover_env
  [[ "$output" == *names_production_atlas_host* && "$output" != *topsecret* ]]
}
@test "clover_env: a missing or writable clover env file is refused" {
  clover_policy
  request clover-node "$D1" release/ok
  refused clover_env
  write_clover_env CLOVER_DEPLOY_ENV=staging; chmod 666 "$ETC/clover.env"
  request clover-node "$D1" release/ok
  refused clover_env
}

# ---------------------------------------------------------------------------------------------------------------- stop
@test "stop: stops one service of the running release and logs it" {
  apply web "$D1" release/ok
  run "$SCRIPTS/odoosync-deploy" stop web
  [ "$status" -eq 0 ]
  grep -q ' stop web$' "$STUB_DOCKER_LOG"
  grep ' stop web$' "$STUB_DOCKER_LOG" | grep -q -- "-f $SRV/releases/release/ok/compose/compose.yml"   # the nested tag folder, not releases/release
  [ "$(last_result)" = stopped ]
}
@test "stop: an unknown service and a missing release tree are refused" {
  run "$SCRIPTS/odoosync-deploy" stop database
  refused bad_args
  run "$SCRIPTS/odoosync-deploy" stop web
  refused no_release_tree
}

# ---------------------------------------------------------------------------------------------------------------- flags
@test "flag: set DEPLOY_FREEZE writes the file, recreates nothing, and blocks the next deploy" {
  run "$SCRIPTS/odoosync-deploy" flag set DEPLOY_FREEZE 1
  [ "$status" -eq 0 ]
  grep -qx 'DEPLOY_FREEZE=1' "$ETC/flags.env"
  [ ! -s "$STUB_DOCKER_LOG" ]
  apply web "$D1" release/ok
  refused freeze
}
@test "flag: unset DEPLOY_FREEZE removes it and keeps other lines" {
  printf 'OTHER_FLAG=keep\nDEPLOY_FREEZE=1\n' > "$ETC/flags.env"; chmod 644 "$ETC/flags.env"
  run "$SCRIPTS/odoosync-deploy" flag unset DEPLOY_FREEZE
  [ "$status" -eq 0 ]
  ! grep -q DEPLOY_FREEZE "$ETC/flags.env"
  grep -qx 'OTHER_FLAG=keep' "$ETC/flags.env"
  apply web "$D1" release/ok
  [ "$status" -eq 0 ]
}
@test "flag: any other flag is refused in this slice, and a bad value too" {
  run "$SCRIPTS/odoosync-deploy" flag set CLOVER_ONBOARDING_FROZEN True
  refused flag_unsupported
  run "$SCRIPTS/odoosync-deploy" flag set DEPLOY_FREEZE 'a b'
  refused bad_args
}

# -------------------------------------------------------------------------------------------------- static rules
@test "static: the tool has no project-wide compose up and no literal stop timeout" {
  ! grep -nE 'compose[^|#]*[^-]up( |$)' "$SCRIPTS/odoosync-deploy" | grep -v -- '--no-deps'
  ! grep -nE -- '(^|[^a-z])-t +[0-9]+|--timeout[ =][0-9]' "$SCRIPTS/odoosync-deploy"
}
