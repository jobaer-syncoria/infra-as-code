#!/usr/bin/env bats
# odoosync-deploy request: INFRA-DEP-04 (guards) and INFRA-DEP-05 (trust chain). Every refusal has a test.
load helpers

setup() { make_sandbox; }
teardown() { rm -rf "$ROOT"; }

refused() { [ "$status" -eq 3 ] && [[ "$output" == *"deploy_refused $1"* ]]; }

# ---------------------------------------------------------------------------------------------------------------- baseline
@test "a fully valid request passes every guard" {
  request web "$D1" release/ok
  [ "$status" -eq 0 ]
  [[ "$output" == *request_ok* ]]
}

@test "without --check-only a request that passed the guards goes on to apply (production refuses a payment-path service)" {
  run "$SCRIPTS/odoosync-deploy" request --env /etc/odoosync/env --service web --digest "$D1" --ref release/ok
  [ "$status" -eq 3 ]
  [[ "$output" == *"deploy_refused apply_needs_bluegreen"* ]]
}

@test "every refusal is also written to the journal as deploy_refused" {
  request web "$D1" release/nope
  refused tag_unknown
  grep -q "deploy_refused tag_unknown" "$ROOT/logger.log"
}

# ---------------------------------------------------------------------------------------------------------- 1. the grammar
@test "grammar: --env must be /etc/odoosync/env" {
  run "$SCRIPTS/odoosync-deploy" request --env /tmp/evil --service web --digest "$D1" --ref release/ok --check-only
  refused bad_args
}
@test "grammar: an unknown service is refused" {
  request database "$D1" release/ok
  refused bad_args
}
@test "grammar: a digest must be sha256: plus 64 hex characters" {
  request web "sha256:abc" release/ok;                        refused bad_args
  request web "latest" release/ok;                             refused bad_args
  request web "sha256:$(printf 'G%.0s' $(seq 64))" release/ok; refused bad_args
}
@test "grammar: a ref with .. or a leading dash is refused" {
  request web "$D1" "release/../x"; refused bad_args
  request web "$D1" "-delete";      refused bad_args
}
@test "grammar: an unknown option is refused" {
  request web "$D1" release/ok --run-as-root
  refused bad_args
}

# --------------------------------------------------------------------------------------------- INFRA-DEP-04: the guards
@test "DEP-04: DEPLOY_FREEZE set refuses" {
  printf 'DEPLOY_FREEZE=1\n' > "$ETC/flags.env"; chmod 644 "$ETC/flags.env"
  request web "$D1" release/ok
  refused freeze
}
@test "DEP-04: DEPLOY_FREEZE empty or 0 does not refuse" {
  printf 'DEPLOY_FREEZE=\n' > "$ETC/flags.env"; chmod 644 "$ETC/flags.env"
  request web "$D1" release/ok; [ "$status" -eq 0 ]
  printf 'DEPLOY_FREEZE=0\n' > "$ETC/flags.env"
  request web "$D1" release/ok; [ "$status" -eq 0 ]
}
@test "DEP-04: a frozen deploy is allowed only with --manual" {
  printf 'DEPLOY_FREEZE=1\n' > "$ETC/flags.env"; chmod 644 "$ETC/flags.env"
  request web "$D1" release/ok --manual
  [ "$status" -eq 0 ]
}
@test "DEP-04: a digest outside the image list is refused (upstream image not pinned in the compose file at the tag)" {
  request edge "$D1" release/ok
  refused digest_not_listed
}
@test "DEP-04: an upstream image pinned in the compose file at the tag is accepted" {
  set_env staging
  request edge "$D2" release/ok
  [ "$status" -eq 0 ]
}
@test "DEP-04: a service with no image in the signed policy is refused" {
  request pgbackup "$D1" release/ok
  refused digest_not_listed
}
@test "DEP-04: production refuses an image whose Python label is below 3.12" {
  STUB_LABELS='{"org.syncoria.python":"3.11.9","org.syncoria.django":"5.2.1"}' request web "$D1" release/ok
  refused label_python
}
@test "DEP-04: production refuses an image whose Django label is below 5.2" {
  STUB_LABELS='{"org.syncoria.python":"3.12.4","org.syncoria.django":"5.1.9"}' request web "$D1" release/ok
  refused label_django
}
@test "DEP-04: production refuses an image with no labels at all" {
  STUB_LABELS='{}' request web "$D1" release/ok
  refused label_python
}
@test "DEP-04: staging does not apply the production label matrix" {
  set_env staging
  STUB_LABELS='{"org.syncoria.python":"3.10"}' request web "$D1" release/ok
  [ "$status" -eq 0 ]
}
@test "DEP-04: a database below PostgreSQL 14 is refused" {
  STUB_PGVER=130012 request web "$D1" release/ok
  refused db_version
}
@test "DEP-04: the database version is read from the postgres container of THIS project, as the policy's user" {
  printf 'OMNISYNC_DEPLOY_ENV=staging\nOMNISYNC_COMPOSE_PROJECT=omnisync-stg\n' > "$ETC/env"; chmod 644 "$ETC/env"
  policy_add '.pg_user = "omnisync"'
  request web "$D1" release/ok
  [ "$status" -eq 0 ]
  grep -q -- 'label=com.docker.compose.project=omnisync-stg' "$STUB_DOCKER_LOG"
  grep -q -- 'label=com.docker.compose.service=postgres' "$STUB_DOCKER_LOG"
  grep -q -- 'exec cid-pg psql -U omnisync -d postgres' "$STUB_DOCKER_LOG"
  ! grep -q -- 'compose -p omnisync exec' "$STUB_DOCKER_LOG"
}
@test "DEP-04: no running postgres container means the version cannot be proven, so the deploy is refused" {
  STUB_NO_PG=1 request web "$D1" release/ok
  refused db_version
}
@test "DEP-04: an unreadable database version is refused" {
  STUB_PGVER=unknown request web "$D1" release/ok
  refused db_version
}
@test "DEP-04: a serving_values.json that differs from the infra copy is refused" {
  printf '{"proxy_read_timeout":999}\n' > "$ROOT/other.json"
  STUB_SERVING_FILE="$ROOT/other.json" request web "$D1" release/ok
  refused serving_values
}
@test "DEP-04: the tier1 override is refused once E1_FINAL exists" {
  printf '%s\n' "$D1" > "$ETC/trust/tier1-baseline.digest"; chmod 644 "$ETC/trust/tier1-baseline.digest"
  touch "$SRV/state/E1_FINAL"
  request web "$D1" release/ok --override tier1-baseline
  refused tier1_after_final
}
@test "DEP-04: the tier1 override accepts only the one recorded digest" {
  printf '%s\n' "$D2" > "$ETC/trust/tier1-baseline.digest"; chmod 644 "$ETC/trust/tier1-baseline.digest"
  request web "$D1" release/ok --override tier1-baseline
  refused tier1_digest_mismatch
}
@test "DEP-04: the tier1 override skips the label and serving_values checks, never the signature" {
  printf '%s\n' "$D1" > "$ETC/trust/tier1-baseline.digest"; chmod 644 "$ETC/trust/tier1-baseline.digest"
  printf '{"x":1}\n' > "$ROOT/other.json"
  STUB_LABELS='{}' STUB_SERVING_FILE="$ROOT/other.json" request web "$D1" release/ok --override tier1-baseline
  [ "$status" -eq 0 ]
  STUB_COSIGN_FAIL=1 request web "$D1" release/ok --override tier1-baseline
  refused signature_invalid
}

# ----------------------------------------------------------------------------------------- INFRA-DEP-05: the trust chain
@test "DEP-05: a tag that does not exist is refused" {
  request web "$D1" release/nope
  refused tag_unknown
}
@test "DEP-05: an unsigned (lightweight) tag is refused" {
  git -C "$WORK" tag release/unsigned production
  git -C "$WORK" push -q "$SRV/infra.git" refs/tags/release/unsigned
  request web "$D1" release/unsigned
  refused tag_unverified
}
@test "DEP-05: an annotated but unsigned tag is refused" {
  git -C "$WORK" tag -a -m x release/annot production
  git -C "$WORK" push -q "$SRV/infra.git" refs/tags/release/annot
  request web "$D1" release/annot
  refused tag_unverified
}
@test "DEP-05: a tag signed by an unknown key is refused" {
  signed_tag release/stranger "$KEYS/stranger"
  request web "$D1" release/stranger
  refused tag_unverified
}
@test "DEP-05: a signed tag that is not reachable from production is refused" {
  git -C "$WORK" switch -q -c side
  printf 'x\n' > "$WORK/side.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m side
  signed_tag release/side "$KEYS/approver" side
  request web "$D1" release/side
  refused tag_not_on_production
}
@test "DEP-05: an image signed by a branch workflow is refused" {
  STUB_COSIGN_OK_IDENTITY="$IDENT_BRANCH" request web "$D1" release/ok
  refused signature_invalid
}
@test "DEP-05: an unsigned image is refused" {
  STUB_COSIGN_FAIL=1 request web "$D1" release/ok
  refused signature_invalid
}
@test "DEP-05: a production digest absent from the signed releases/production.json is refused" {
  request web "$D2" release/ok
  refused prod_digest_mismatch
}
@test "DEP-05: a service missing from releases/production.json is refused on production" {
  request worker "$D1" release/ok
  refused prod_digest_mismatch
}
@test "DEP-05: production also needs releases/production.json to name an upstream image's digest" {
  request edge "$D2" release/ok
  refused prod_digest_mismatch
}
@test "DEP-05: staging does not need the release file to name the digest" {
  set_env staging
  request web "$D2" release/ok
  [ "$status" -eq 0 ]
}
@test "DEP-05: a trust file writable by group or others is never read" {
  chmod 664 "$ETC/trust/image-policy.json"
  request web "$D1" release/ok
  refused trust_file_unsafe
  chmod 644 "$ETC/trust/image-policy.json"; chmod 666 "$ETC/trust/allowed_signers"
  request web "$D1" release/ok
  refused trust_file_unsafe
  chmod 644 "$ETC/trust/allowed_signers"; chmod 660 "$ETC/env"
  request web "$D1" release/ok
  refused trust_file_unsafe
}
@test "DEP-05: a symlinked trust file is never read" {
  mv "$ETC/trust/image-policy.json" "$ROOT/real-policy.json"; ln -s "$ROOT/real-policy.json" "$ETC/trust/image-policy.json"
  request web "$D1" release/ok
  refused trust_file_unsafe
}
@test "DEP-05: an unknown deploy environment is refused" {
  set_env sandbox
  request web "$D1" release/ok
  refused bad_env
}
