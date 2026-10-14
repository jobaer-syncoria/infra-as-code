#!/usr/bin/env bats
# odoosync-promote: the approver-side promotion guard (A8-15) and the restore-test gate (INFRA-PG-11-10).
# A sandbox clone with a bare "origin" and stand-ins for cosign, docker, curl and gh. No network.

SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS/.." && pwd)"
DG="sha256:$(printf 'a%.0s' $(seq 64))"
REV="1111111111111111111111111111111111111111"

setup() {
  T="$(mktemp -d)"; STUBS="$T/stubs"; mkdir -p "$STUBS"
  git init -q --bare -b production "$T/origin.git"
  git init -q -b production "$T/w"
  git -C "$T/w" config user.email t@test; git -C "$T/w" config user.name t
  mkdir -p "$T/w/config" "$T/w/ops" "$T/w/releases"
  cp "$REPO_ROOT/config/promote.json" "$T/w/config/"
  echo '{"web":"sha256:'"$(printf 'f%.0s' $(seq 64))"'"}' > "$T/w/releases/production.json"
  printf '{"last_result":"passed","last_date":"%s"}\n' "$(date -d '5 days ago' +%F)" > "$T/w/ops/restore-test.json"
  git -C "$T/w" add -A; git -C "$T/w" commit -q -m base
  git -C "$T/w" remote add origin "$T/origin.git"; git -C "$T/w" push -q origin production
  cat > "$STUBS/cosign" <<'EOS'
#!/usr/bin/env bash
[ -z "${STUB_COSIGN_FAIL:-}" ] || { echo "Error: ${STUB_COSIGN_FAIL}" >&2; exit 1; }
EOS
  cat > "$STUBS/docker" <<'EOS'
#!/usr/bin/env bash
[ -n "${STUB_REV:-}" ] || exit 1
printf '{"config":{"Labels":{"org.opencontainers.image.revision":"%s"}}}\n' "$STUB_REV"
EOS
  cat > "$STUBS/curl" <<'EOS'
#!/usr/bin/env bash
[ -z "${STUB_CURL_FAIL:-}" ] || exit 7
printf '{"release":"%s"}\n' "$STUB_RUNNING"
EOS
  cat > "$STUBS/gh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  api) [ -z "${STUB_GH_FAIL:-}" ] || exit 1
       printf '[{"context":"other","state":"success"},{"context":"sit-staging/regression","state":"%s"}]\n' "${STUB_STATE:-success}" ;;
  pr) printf '%s\n' "$*" >> "$STUB_ROOT/gh.pr" ;;
esac
EOS
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH" STUB_ROOT="$T" STUB_REV="$REV" STUB_RUNNING="$REV" STUB_STATE=success
  cd "$T/w"
}
teardown() { rm -rf "$T"; }

promote() { run "$SCRIPTS/odoosync-promote" "$@"; }

@test "all four checks pass: PR branch, production.json pinned, notes written, nothing merged or signed" {
  promote web "$DG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sit-staging/regression is green"* ]]
  [ "$(git -C "$T/w" branch --show-current)" != production ]
  [ "$(jq -r .web releases/production.json)" = "$DG" ]
  grep -q "revision: $REV" releases/promotion-notes.txt
  grep -q "pr create" "$T/gh.pr"
  git -C "$T/origin.git" branch | grep -q promote/web-
  [ "$(git -C "$T/origin.git" rev-parse production)" = "$(git -C "$T/w" rev-parse origin/production)" ]
  [ -z "$(git -C "$T/origin.git" tag)" ]
}

@test "dry run writes nothing" {
  promote web "$DG" --dry-run
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = production ]
  [ -z "$(git status --porcelain)" ]
  [ ! -f "$T/gh.pr" ]
}

@test "a service that is not configured is refused" {
  promote admin-web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"unknown_service"* ]]
}

@test "a malformed digest is refused" {
  promote web sha256:abc
  [ "$status" -eq 3 ]; [[ "$output" == *"bad_digest"* ]]
}

@test "a bad signature is refused with cosign's reason and nothing is written" {
  STUB_COSIGN_FAIL="no matching signatures" promote web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"signature_invalid Error: no matching signatures"* ]]
  [ "$(git branch --show-current)" = production ]
}

@test "staging running another revision is refused, and no override can bypass it" {
  STUB_RUNNING="2222222222222222222222222222222222222222" promote web "$DG" --override-status "x" --override-restore "y"
  [ "$status" -eq 3 ]; [[ "$output" == *"staging_runs_other_revision"* ]]
}

@test "staging unreachable is refused" {
  STUB_CURL_FAIL=1 promote web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"staging_unreachable"* ]]
}

@test "a missing revision label is refused" {
  STUB_REV="" promote web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"no_revision_label"* ]]
}

@test "a red regression status is refused" {
  STUB_STATE=failure promote web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"regression_status_failure"* ]]
  [ "$(git branch --show-current)" = production ]
}

@test "an unreadable status is refused" {
  STUB_GH_FAIL=1 promote web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"regression_status_"* ]]
}

@test "a red status with an override reason goes through and the reason is recorded" {
  STUB_STATE=failure promote web "$DG" --override-status "hotfix for invoice crash, approved by lead"
  [ "$status" -eq 0 ]
  grep -q "OVERRIDE by approver: hotfix for invoice crash" releases/promotion-notes.txt
}

# INFRA-PG-11-10
@test "INFRA-PG-11-10: no passed restore test in 35 days is refused" {
  printf '{"last_result":"passed","last_date":"%s"}\n' "$(date -d '40 days ago' +%F)" > ops/restore-test.json
  git add -A; git commit -q -m old
  promote web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"restore_test_passed_age_40"* ]]
}

@test "INFRA-PG-11-10: a failed last restore test is refused even when recent" {
  printf '{"last_result":"failed","last_date":"%s"}\n' "$(date -d '1 day ago' +%F)" > ops/restore-test.json
  git add -A; git commit -q -m failed
  promote web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"restore_test_failed"* ]]
}

@test "INFRA-PG-11-10: the record that says none (never tested) is refused" {
  printf '{"last_result":"none","last_date":"1970-01-01"}\n' > ops/restore-test.json
  git add -A; git commit -q -m none
  promote web "$DG"
  [ "$status" -eq 3 ]
}

@test "INFRA-PG-11-10: an override reason lets an overdue restore test through and is recorded" {
  printf '{"last_result":"passed","last_date":"%s"}\n' "$(date -d '40 days ago' +%F)" > ops/restore-test.json
  git add -A; git commit -q -m old
  promote web "$DG" --override-restore "restore droplet down, rerun scheduled"
  [ "$status" -eq 0 ]
  grep -q "restore test: passed .*OVERRIDE by approver: restore droplet down" releases/promotion-notes.txt
}

@test "a dirty working tree is refused" {
  echo x > stray.txt
  promote web "$DG"
  [ "$status" -eq 3 ]; [[ "$output" == *"working_tree_not_clean"* ]]
}

@test "the tool never signs, merges or handles a token" {
  ! grep -nE "tag -s|pr merge|gh auth token|GITHUB_TOKEN|--force" "$SCRIPTS/odoosync-promote"
}

@test "make-release-tag puts the promotion notes in the signed tag message" {
  grep -q 'promotion-notes.txt' "$SCRIPTS/make-release-tag.sh"
}
