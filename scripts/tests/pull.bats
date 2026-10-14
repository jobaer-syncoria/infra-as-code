#!/usr/bin/env bats
# odoosync-pull: tag selection, per-service decisions, freeze, lock, failure handling. The deploy tool is replaced by a recorder.
load helpers

setup() {
  make_sandbox; set_env staging
  policy_add '.pull = {"tag":"staging","services":["web","worker"]}'
  export STUB_REGISTRY_DIGEST="$D1"
  PULL="$SCRIPTS/odoosync-pull"; CALLS="$ROOT/deploy.calls"
}
teardown() { rm -rf "$ROOT"; }

# remove the baseline tag from BOTH the origin and the clone (the agent fetches from the origin and prunes)
drop_ok_tag() { git -C "$WORK" tag -d release/ok >/dev/null; git -C "$SRV/infra.git" tag -d release/ok >/dev/null; }
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" || echo 0; }
ok_entry() { printf '{"ts":"t","service":"%s","repo":"r","digest":"%s","ref":"x","result":"ok","operator":"t"}\n' "$1" "$2" >> "$SRV/state/releases.jsonl"; }
stamp() { git -C "$WORK" -c gpg.format=ssh -c "user.signingkey=$2" tag -s -m x "$1" "${3:-production}"; }

# ------------------------------------------------------------------------------------------------------ happy paths
@test "staging: a changed registry digest is applied to every service through odoosync-deploy" {
  run "$PULL"
  [ "$status" -eq 0 ]; [[ "$output" == *"pull_ok release/ok applied=2"* ]]
  [ "$(calls)" -eq 2 ]
  grep -q -- "request --env /etc/odoosync/env --service web --digest $D1 --ref release/ok" "$CALLS"
  grep -q -- "--service worker --digest $D1 --ref release/ok" "$CALLS"
}
@test "no change: the same digest as the last successful release is a no-op" {
  ok_entry web "$D1"; ok_entry worker "$D1"
  run "$PULL"
  [ "$status" -eq 0 ]; [[ "$output" == *"pull_noop web"* && "$output" == *"pull_noop worker"* && "$output" == *"applied=0"* ]]
  [ "$(calls)" -eq 0 ]
}
@test "only the service whose digest changed is applied" {
  ok_entry web "$D1"; ok_entry worker "$D3"
  run "$PULL"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]; grep -q -- "--service worker" "$CALLS"
}
@test "a failed or rolled back release is never taken as the current one" {
  printf '{"ts":"t","service":"web","repo":"r","digest":"%s","ref":"x","result":"failed","operator":"t"}\n' "$D1" >> "$SRV/state/releases.jsonl"
  run "$PULL"
  grep -q -- "--service web --digest $D1" "$CALLS"
}
@test "tags created after the clone are fetched" {
  drop_ok_tag
  stamp release/20261020-1 "$KEYS/approver"            # only in the work repo (the 'origin'), not pushed to the clone
  run "$PULL"
  [ "$status" -eq 0 ]; grep -q -- "--ref release/20261020-1" "$CALLS"
}

# ----------------------------------------------------------------------------------------------------- tag selection
@test "tags: the newest by version order wins (-10 is newer than -9)" {
  drop_ok_tag
  for n in 1 9 10; do signed_tag "release/20261015-$n" "$KEYS/approver"; done
  run "$PULL"
  grep -q -- "--ref release/20261015-10" "$CALLS"
}
@test "tags: an unsigned newest tag is ignored and the older signed one is used" {
  drop_ok_tag
  signed_tag release/20261014-1 "$KEYS/approver"
  git -C "$WORK" tag release/20261015-2 production; git -C "$WORK" push -q "$SRV/infra.git" refs/tags/release/20261015-2
  run "$PULL"
  [[ "$output" == *"pull_ignored_tag release/20261015-2 unverified"* ]]
  grep -q -- "--ref release/20261014-1" "$CALLS"
}
@test "tags: a tag signed by an unknown key is ignored" {
  drop_ok_tag
  signed_tag release/20261015-1 "$KEYS/stranger"
  run "$PULL"
  [[ "$output" == *"pull_ignored_tag release/20261015-1 unverified"* && "$output" == *pull_no_valid_tag* ]]
  [ "$(calls)" -eq 0 ]
}
@test "tags: a signed tag that is not reachable from production is ignored" {
  drop_ok_tag
  git -C "$WORK" switch -q -c side; printf 'x\n' > "$WORK/s.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m side
  signed_tag release/20261015-1 "$KEYS/approver" side
  run "$PULL"
  [[ "$output" == *"pull_ignored_tag release/20261015-1 not_on_production"* ]]
  [ "$(calls)" -eq 0 ]
}
@test "tags: with no valid tag at all nothing happens and the registry is not asked" {
  drop_ok_tag
  run "$PULL"
  [ "$status" -eq 0 ]; [[ "$output" == *pull_no_valid_tag* ]]
  ! grep -q buildx "$STUB_DOCKER_LOG"
}

# ------------------------------------------------------------------------------------------------------- guards
@test "freeze: DEPLOY_FREEZE set means do nothing at all" {
  printf 'DEPLOY_FREEZE=1\n' > "$ETC/flags.env"; chmod 644 "$ETC/flags.env"
  run "$PULL"
  [ "$status" -eq 0 ]; [[ "$output" == *pull_frozen* ]]
  [ "$(calls)" -eq 0 ]; ! grep -q buildx "$STUB_DOCKER_LOG"
}
@test "lock: a second run while one is running exits quietly" {
  exec 7>"$SRV/state/pull.lock"; flock -n 7
  run "$PULL"
  [ "$status" -eq 0 ]; [[ "$output" == *pull_busy* ]]
  [ "$(calls)" -eq 0 ]
  flock -u 7
}
@test "trust files writable by others are never read" {
  chmod 664 "$ETC/trust/image-policy.json"
  run "$PULL"
  [ "$status" -eq 3 ]; [[ "$output" == *pull_trust_file_unsafe* ]]
}
@test "a missing clone is reported, not created" {
  rm -rf "$SRV/infra.git"
  run "$PULL"
  [ "$status" -eq 3 ]; [[ "$output" == *pull_no_clone* ]]
}
@test "fetch failure: nothing is deployed from stale data" {
  git -C "$SRV/infra.git" remote set-url origin /nonexistent/repo
  run "$PULL"
  [ "$status" -eq 1 ]; [[ "$output" == *pull_fetch_failed* ]]
  [ "$(calls)" -eq 0 ]
}

# ------------------------------------------------------------------------------------------------- failure handling
@test "registry failure: reported, nothing is applied, exit 1" {
  STUB_REGISTRY_FAIL=1 run "$PULL"
  [ "$status" -eq 1 ]; [[ "$output" == *"pull_registry_failed web"* ]]
  [ "$(calls)" -eq 0 ]
}
@test "registry answer that is not a digest is a failure" {
  STUB_REGISTRY_DIGEST="latest" run "$PULL"
  [ "$status" -eq 1 ]; [[ "$output" == *pull_registry_failed* ]]
}
@test "the first failure stops the run: the next service is not attempted" {
  STUB_DEPLOY_RC=3 run "$PULL"
  [ "$status" -eq 3 ]; [[ "$output" == *"pull_failed web rc=3"* ]]
  [ "$(calls)" -eq 1 ]
}
@test "a deploy that is busy (a person is deploying) makes the run end quietly" {
  STUB_DEPLOY_BUSY=1 run "$PULL"
  [ "$status" -eq 0 ]; [[ "$output" == *pull_busy* ]]
}
@test "staging with no registry tag configured does nothing" {
  policy_add 'del(.pull.tag)'
  run "$PULL"
  [ "$status" -eq 0 ]; [[ "$output" == *pull_no_tag_configured* ]]
  [ "$(calls)" -eq 0 ]
}

# ------------------------------------------------------------------------------------------------------- production
@test "production: digests come from the signed releases/production.json, the registry is never asked" {
  set_env production
  policy_add '.pull = {"services":["web","worker"]}'
  STUB_REGISTRY_FAIL=1 run "$PULL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pull_not_in_release worker"* ]]
  [ "$(calls)" -eq 1 ]; grep -q -- "--service web --digest $D1 --ref release/ok" "$CALLS"
  ! grep -q buildx "$STUB_DOCKER_LOG"
}

# ------------------------------------------------------------------------------------------------------- static
@test "static: the pull agent contains no secret handling, no build and no project-wide compose up" {
  ! grep -nE 'docker (build|compose)( |$)|--password|login|TOKEN|SECRET' "$SCRIPTS/odoosync-pull"
}
