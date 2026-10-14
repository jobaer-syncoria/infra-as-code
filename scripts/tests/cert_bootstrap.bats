#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2164,SC2314   # stub bodies are single-quoted on purpose; `! grep` is the last command
# cert-bootstrap.sh: first certificate issuance. A sandbox with stand-ins for certbot, curl and docker. No network, no root.

SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  ROOT="$(mktemp -d)"; export ODOOSYNC_TEST_ROOT="$ROOT"
  ETC="$ROOT/etc/odoosync"; RFS="$ROOT/rootfs"; STUBS="$ROOT/stubs"
  mkdir -p "$ETC/trust" "$RFS/etc/letsencrypt" "$RFS/srv/certbot/www" "$STUBS"
  printf 'OMNISYNC_DEPLOY_ENV=production\nOMNISYNC_COMPOSE_PROJECT=proj\n' > "$ETC/env"; chmod 644 "$ETC/env"
  cat > "$ETC/trust/image-policy.json" <<'JSON'
{"certs":{"email":"ops@example.com","certs":{"odoosync.com":["odoosync.com","www.odoosync.com"],"api.odoosync.com":["api.odoosync.com"]}}}
JSON
  chmod 644 "$ETC/trust/image-policy.json"
  export STUB_ROOT="$ROOT" STUB_RFS="$RFS"
  # certbot: records its arguments; creates a real self-signed certificate under live/<cert-name>
  cat > "$STUBS/certbot" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ROOT/certbot.calls"
name=""; prev=""
for a in "$@"; do [ "$prev" = --cert-name ] && name="$a"; prev="$a"; done
[ "$name" != "${STUB_CERTBOT_FAIL:-}" ] || { echo "Error: too many failed authorizations" >&2; exit 1; }
case " $* " in *" --dry-run "*) exit 0 ;; esac
d="$STUB_RFS/etc/letsencrypt/live/$name"; mkdir -p "$d"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/privkey.pem" -out "$d/fullchain.pem" -days 90 -subj "/CN=$name" 2>/dev/null
chmod "${STUB_KEY_MODE:-600}" "$d/privkey.pem"
EOS
  # curl: serves the probe file from the sandbox webroot unless STUB_EDGE_DOWN names that host
  cat > "$STUBS/curl" <<'EOS'
#!/usr/bin/env bash
url="${@: -1}"; host="${url#http://}"; host="${host%%/*}"
[ "$host" != "${STUB_EDGE_DOWN:-}" ] || exit 22
cat "$STUB_RFS/srv/certbot/www/.well-known/acme-challenge/${url##*/}"
EOS
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
}
teardown() { rm -rf "$ROOT"; }
cb() { run "$SCRIPTS/cert-bootstrap.sh" "$@"; echo "$output"; }

@test "issues every certificate, installs the hook, and reports key mode and expiry" {
  cb
  [ "$status" -eq 0 ]; [[ "$output" == *"cert_bootstrap_ok"* ]]
  [ "$(wc -l < "$ROOT/certbot.calls")" -eq 2 ]
  [[ "$output" == *"PASS cert odoosync.com"* && "$output" == *"PASS cert api.odoosync.com"* ]]
  [[ "$output" == *"PASS key_mode odoosync.com 600"* ]]
  [[ "$output" == *"INFO notAfter odoosync.com"* ]]
}

@test "one certbot run per certificate, webroot mode, both domains of the first, keep-until-expiring" {
  cb
  grep -q -- "--cert-name odoosync.com .*-d odoosync.com -d www.odoosync.com" "$ROOT/certbot.calls"
  grep -q -- "--webroot" "$ROOT/certbot.calls"
  grep -q -- "--keep-until-expiring" "$ROOT/certbot.calls"
  grep -q -- "-m ops@example.com" "$ROOT/certbot.calls"
}

@test "the deploy hook reloads nginx in the edge container of this project" {
  cb
  HOOK="$RFS/etc/letsencrypt/renewal-hooks/deploy/odoosync-edge-reload"
  [ -x "$HOOK" ]
  grep -q "com.docker.compose.project=proj" "$HOOK"
  grep -q "service=edge" "$HOOK"
  grep -q "nginx -s reload" "$HOOK"
}

@test "one failing certificate does not stop the others, and the exit code is 1" {
  STUB_CERTBOT_FAIL=odoosync.com cb
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL cert odoosync.com: Error: too many failed authorizations"* ]]
  [[ "$output" == *"PASS cert api.odoosync.com"* ]]
}

@test "a domain that does not serve the probe stops everything before certbot is called" {
  STUB_EDGE_DOWN=www.odoosync.com cb
  [ "$status" -eq 3 ]; [[ "$output" == *"FAIL probe www.odoosync.com"* ]]; [[ "$output" == *"cert_refused probe_failed"* ]]
  [ ! -f "$ROOT/certbot.calls" ]
}

@test "the probe file is removed afterwards and nothing else is left in the webroot" {
  cb
  [ -z "$(find "$RFS/srv/certbot/www" -type f)" ]
}

@test "a private key that others can read fails" {
  STUB_KEY_MODE=644 cb
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL key_mode"* ]]
}

@test "dry run passes --dry-run and saves nothing" {
  cb --dry-run
  [ "$status" -eq 0 ]
  grep -q -- "--dry-run" "$ROOT/certbot.calls"
  [ ! -d "$RFS/etc/letsencrypt/live" ]
}

@test "a placeholder or missing contact email is refused" {
  jq '.certs.email = "CHANGE-ME@example.com"' "$ETC/trust/image-policy.json" > "$ROOT/p" && mv "$ROOT/p" "$ETC/trust/image-policy.json"; chmod 644 "$ETC/trust/image-policy.json"
  cb
  [ "$status" -eq 3 ]; [[ "$output" == *"no_contact_email"* ]]
  jq 'del(.certs.email)' "$ETC/trust/image-policy.json" > "$ROOT/p" && mv "$ROOT/p" "$ETC/trust/image-policy.json"; chmod 644 "$ETC/trust/image-policy.json"
  cb
  [ "$status" -eq 3 ]
}

@test "a policy with no certs is refused" {
  jq '.certs.certs = {}' "$ETC/trust/image-policy.json" > "$ROOT/p" && mv "$ROOT/p" "$ETC/trust/image-policy.json"; chmod 644 "$ETC/trust/image-policy.json"
  cb
  [ "$status" -eq 3 ]; [[ "$output" == *"no_certs"* ]]
}

@test "a domain with shell characters is refused" {
  jq '.certs.certs["x.com"] = ["x.com; rm -rf /"]' "$ETC/trust/image-policy.json" > "$ROOT/p" && mv "$ROOT/p" "$ETC/trust/image-policy.json"; chmod 644 "$ETC/trust/image-policy.json"
  cb
  [ "$status" -eq 3 ]; [[ "$output" == *"bad_domain"* ]]
}

@test "a policy file anyone can write is refused" {
  chmod 666 "$ETC/trust/image-policy.json"
  cb
  [ "$status" -eq 3 ]; [[ "$output" == *"trust_file_unsafe"* ]]
}

@test "missing certbot is refused with a clear message" {
  rm "$STUBS/certbot"
  PATH="$STUBS:/usr/bin:/bin" run "$SCRIPTS/cert-bootstrap.sh"
  [ "$status" -eq 3 ]; [[ "$output" == *"no_certbot"* ]]
}

@test "bad use exits 2" {
  cb --nonsense
  [ "$status" -eq 2 ]
}

@test "a rerun is safe: certbot is asked again with keep-until-expiring and still succeeds" {
  cb; cb
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ROOT/certbot.calls")" -eq 4 ]
}

@test "the script never prints a key and never uses force-renewal or the test flag by default" {
  ! grep -nE "cat .*privkey|--force-renewal|--test-cert|--staging" "$SCRIPTS/cert-bootstrap.sh"
}
