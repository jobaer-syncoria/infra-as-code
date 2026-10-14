#!/usr/bin/env bats
# odoosync-secrets: no echo, never argv, atomic 0600, only set/empty/missing and verifies true|false are ever printed.

setup() { ROOT="$(mktemp -d)"; export ODOOSYNC_TEST_ROOT="$ROOT"; mkdir -p "$ROOT/etc/odoosync"; SECRETS="$ROOT/etc/odoosync/secrets.env"; S="$BATS_TEST_DIRNAME/../odoosync-secrets"; }
teardown() { rm -rf "$ROOT"; }

@test "set reads one line from a pipe, writes 0600 and prints only the name" {
  run bash -c "printf '%s\n' 'S3cret-VALUE-1' | '$S' set DJANGO_SECRET_KEY"
  [ "$status" -eq 0 ]
  [ "$output" = "DJANGO_SECRET_KEY set" ]
  [ "$(stat -c %a "$SECRETS")" = 600 ]
  grep -qx 'DJANGO_SECRET_KEY=S3cret-VALUE-1' "$SECRETS"
  [[ "$output" != *S3cret* ]]
}
@test "set refuses a value on the command line (argv is never used)" {
  run "$S" set DJANGO_SECRET_KEY S3cret-VALUE-1
  [ "$status" -eq 2 ]
  [ ! -e "$SECRETS" ]
}
@test "set refuses an empty value, a bad name and a multi-line value" {
  run bash -c "printf '\n' | '$S' set DJANGO_SECRET_KEY";   [ "$status" -eq 2 ]
  run bash -c "printf 'x\n' | '$S' set lowercase";           [ "$status" -eq 2 ]
  run bash -c "printf 'x\n' | '$S' set 'A B'";               [ "$status" -eq 2 ]
  [ ! -e "$SECRETS" ]
}
@test "set replaces a value without duplicating the line or touching the others" {
  run bash -c "printf 'one\n' | '$S' set AAA_KEY && printf 'two\n' | '$S' set BBB_KEY && printf 'three\n' | '$S' set AAA_KEY"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^AAA_KEY=' "$SECRETS")" -eq 1 ]
  grep -qx 'AAA_KEY=three' "$SECRETS"
  grep -qx 'BBB_KEY=two' "$SECRETS"
  [ "$(stat -c %a "$SECRETS")" = 600 ]
  [ -z "$(ls "$ROOT/etc/odoosync" | grep -v '^secrets.env$' || true)" ]
}
@test "check prints set, empty or missing and never a value" {
  printf 'HAS_VALUE=topsecretvalue\nEMPTY_ONE=\n' > "$SECRETS"; chmod 600 "$SECRETS"
  run "$S" check HAS_VALUE EMPTY_ONE NOT_THERE
  [ "$status" -eq 0 ]
  [[ "$output" == *"HAS_VALUE set"* ]]
  [[ "$output" == *"EMPTY_ONE empty"* ]]
  [[ "$output" == *"NOT_THERE missing"* ]]
  [[ "$output" != *topsecretvalue* ]]
}
@test "check without names lists every name in the file, still no values" {
  printf 'ONE_KEY=aaa111\nTWO_KEY=bbb222\n' > "$SECRETS"; chmod 600 "$SECRETS"
  run "$S" check
  [[ "$output" == *"ONE_KEY set"* && "$output" == *"TWO_KEY set"* ]]
  [[ "$output" != *aaa111* && "$output" != *bbb222* ]]
}
@test "a secrets file writable by group or others is refused" {
  printf 'A_KEY=x\n' > "$SECRETS"; chmod 660 "$SECRETS"
  run "$S" check A_KEY
  [ "$status" -ne 0 ]
  run bash -c "printf 'y\n' | '$S' set B_KEY"
  [ "$status" -ne 0 ]
}

mk_token() {  # mk_token <secret> <file>
  python3 - "$1" "$2" <<'PY'
import base64, hashlib, hmac, json, sys
b = lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = b(json.dumps({"sub": "1"}).encode())
s = b(hmac.new(sys.argv[1].encode(), h + b"." + p, hashlib.sha256).digest())
open(sys.argv[2], "w").write((h + b"." + p + b"." + s).decode())
PY
}
@test "hs256-check: true with the right secret, false with another, and only length is shown" {
  printf 'JWT_KEY=correct-horse-battery\n' > "$SECRETS"; chmod 600 "$SECRETS"
  mk_token correct-horse-battery "$ROOT/good.tok"; mk_token another-secret-value "$ROOT/bad.tok"
  run "$S" hs256-check JWT_KEY "$ROOT/good.tok"
  [ "$status" -eq 0 ]; [[ "$output" == *"verifies true"* && "$output" == *"length 21"* ]]
  [[ "$output" != *correct-horse* ]]
  run "$S" hs256-check JWT_KEY "$ROOT/bad.tok"
  [[ "$output" == *"verifies false"* ]]
}
@test "hs256-check --stdin reads the secret from stdin, not from the file" {
  mk_token workstation-secret "$ROOT/t.tok"
  run bash -c "printf 'workstation-secret\n' | '$S' hs256-check --stdin '$ROOT/t.tok'"
  [[ "$output" == *"verifies true"* && "$output" == *"length 18"* && "$output" != *workstation-secret* ]]
}
@test "hs256-check on a missing or empty secret prints verifies false and length 0" {
  printf 'JWT_KEY=\n' > "$SECRETS"; chmod 600 "$SECRETS"
  mk_token x "$ROOT/t.tok"
  run "$S" hs256-check JWT_KEY "$ROOT/t.tok"
  [[ "$output" == *"verifies false"* && "$output" == *"length 0"* ]]
}
