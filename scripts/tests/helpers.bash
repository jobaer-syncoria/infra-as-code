# shellcheck shell=bash disable=SC2034
# Test sandbox for the odoosync root tools. Everything lives under a temp dir; nothing touches /etc or /srv.
# The tools only honour ODOOSYNC_TEST_ROOT when run as a NON-root user (see scripts/lib/common.sh).

SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
D1="sha256:$(printf 'a%.0s' $(seq 64))"      # the digest of the image under test
D2="sha256:$(printf 'b%.0s' $(seq 64))"      # some other digest
IDENT_PROD="https://github.com/syncoria/omnisync/.github/workflows/release.yml@refs/heads/production"
IDENT_BRANCH="https://github.com/syncoria/omnisync/.github/workflows/release.yml@refs/heads/feature-x"
ISSUER="https://token.actions.githubusercontent.com"

make_sandbox() {
  ROOT="$(mktemp -d)"; export ODOOSYNC_TEST_ROOT="$ROOT"
  ETC="$ROOT/etc/odoosync"; SRV="$ROOT/srv/odoosync"; KEYS="$ROOT/keys"; STUBS="$ROOT/stubs"; WORK="$ROOT/work"
  mkdir -p "$ETC/trust" "$SRV/state" "$SRV/releases" "$KEYS" "$STUBS"
  ssh-keygen -q -t ed25519 -N '' -C approver -f "$KEYS/approver"
  ssh-keygen -q -t ed25519 -N '' -C stranger -f "$KEYS/stranger"
  printf 'approver@test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$KEYS/approver.pub")" > "$ETC/trust/allowed_signers"
  chmod 644 "$ETC/trust/allowed_signers"
  write_policy
  set_env production
  # the infra repo: one commit on production with the files the guards read
  git init -q -b production "$WORK"
  git -C "$WORK" config user.email t@test; git -C "$WORK" config user.name t
  mkdir -p "$WORK/compose" "$WORK/nginx" "$WORK/releases"
  printf 'services:\n  edge:\n    image: docker.io/library/nginx@%s\n' "$D2" > "$WORK/compose/compose.yml"
  printf '{"proxy_read_timeout":240}\n' > "$WORK/nginx/serving_values.json"
  printf '{"web":"%s"}\n' "$D1" > "$WORK/releases/production.json"
  git -C "$WORK" add -A; git -C "$WORK" commit -q -m base
  git clone -q --bare "$WORK" "$SRV/infra.git"
  make_stubs
  export PATH="$STUBS:$PATH"
  export STUB_LABELS='{"org.syncoria.python.version":"3.12.4","org.syncoria.django.version":"5.2.1"}'
  export STUB_SERVING_FILE="$WORK/nginx/serving_values.json"
  export STUB_PGVER=170011
  export STUB_COSIGN_OK_IDENTITY="$IDENT_PROD"
  signed_tag release/ok "$KEYS/approver"
}

write_policy() {
  cat > "$ETC/trust/image-policy.json" <<JSON
{
  "services": {"web": "ghcr.io/syncoria/omnisync", "edge": "docker.io/library/nginx", "worker": "ghcr.io/syncoria/omnisync",
               "postgres": "ghcr.io/syncoria/odoosync-postgres"},
  "upstream": ["docker.io/library/nginx"],
  "images": {
    "ghcr.io/syncoria/omnisync": {"identity": "$IDENT_PROD", "issuer": "$ISSUER"},
    "ghcr.io/syncoria/odoosync-postgres": {"identity": "https://github.com/syncoria/odoosync-infra/.github/workflows/templates.yml@refs/heads/production", "issuer": "$ISSUER"}
  },
  "label_checked": ["ghcr.io/syncoria/omnisync"],
  "serving_values_path": "/app/deploy/serving_values.json"
}
JSON
  chmod 644 "$ETC/trust/image-policy.json"
}

set_env() { printf 'OMNISYNC_DEPLOY_ENV=%s\n' "$1" > "$ETC/env"; chmod 644 "$ETC/env"; }

# signed_tag <name> <private key> [commit]   (a tag signed with an SSH key, pushed to the root-owned bare clone)
signed_tag() {
  local name="$1" key="$2" commit="${3:-production}"
  git -C "$WORK" -c gpg.format=ssh -c "user.signingkey=$key" tag -s -m release "$name" "$commit"
  git -C "$WORK" push -q "$SRV/infra.git" "refs/tags/$name"
}

make_stubs() {
  [ -n "$STUBS" ] && [ -d "$STUBS" ] || return 1
  cat > "$STUBS/cosign" <<'COSIGN_END'
#!/usr/bin/env bash
# stand-in for cosign: succeeds only when the identity asked for equals STUB_COSIGN_OK_IDENTITY
[ -z "${STUB_COSIGN_FAIL:-}" ] || exit 1
while [ $# -gt 0 ]; do
  if [ "$1" = --certificate-identity ] && [ "$2" = "${STUB_COSIGN_OK_IDENTITY:-}" ]; then exit 0; fi
  shift
done
exit 1
COSIGN_END
  cat > "$STUBS/docker" <<'DOCKER_END'
#!/usr/bin/env bash
case "$1" in
  image) printf '%s\n' "$STUB_LABELS" ;;
  run) cat "$STUB_SERVING_FILE" ;;
  compose) printf '%s\n' "$STUB_PGVER" ;;
  *) exit 1 ;;
esac
DOCKER_END
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logger.log"\n' "$ROOT" > "$STUBS/logger"
  chmod +x "$STUBS/cosign" "$STUBS/docker" "$STUBS/logger"
}

request() {  # request <service> <digest> <ref> [extra args]
  local s="$1" d="$2" r="$3"; shift 3
  run "$SCRIPTS/odoosync-deploy" request --env /etc/odoosync/env --service "$s" --digest "$d" --ref "$r" --check-only "$@"
}
