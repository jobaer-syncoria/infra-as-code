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
  export STUB_LABELS='{"org.syncoria.python":"3.12.4","org.syncoria.django":"5.2.1"}'
  export STUB_SERVING_FILE="$WORK/nginx/serving_values.json"
  export STUB_PGVER=170011
  export STUB_ROOT="$ROOT" STUB_DOCKER_LOG="$ROOT/docker.log" ODOOSYNC_DEPLOY_BIN="$STUBS/deploy-recorder"
  : > "$STUB_DOCKER_LOG"
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
  "serving_values_path": "/code/deploy/serving_values.json",
  "readiness_timeout": 2,
  "poll_seconds": 0,
  "stable_seconds": 0
}
JSON
  chmod 644 "$ETC/trust/image-policy.json"
}

# policy_add '<jq filter>' : extend the signed policy in the sandbox (e.g. '.required_secrets = {"web":["DJANGO_SECRET_KEY"]}')
policy_add() {
  jq "$1" "$ETC/trust/image-policy.json" > "$ETC/trust/image-policy.json.new" && mv "$ETC/trust/image-policy.json.new" "$ETC/trust/image-policy.json"
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
# stand-in for docker: logs every call to $STUB_DOCKER_LOG; behaviour is steered by STUB_* variables
printf '%s\n' "$*" >> "$STUB_DOCKER_LOG"
case "$1" in
  pull) [ -z "${STUB_PULL_FAIL:-}" ] || exit 1 ;;
  buildx) [ -z "${STUB_REGISTRY_FAIL:-}" ] || exit 1; printf '%s\n' "${STUB_REGISTRY_DIGEST:-}" ;;
  image) printf '%s\n' "$STUB_LABELS" ;;
  ps) [ -n "${STUB_NO_PG:-}" ] || echo cid-pg ;;
  exec) printf '%s\n' "$STUB_PGVER" ;;
  run) cat "$STUB_SERVING_FILE" ;;
  inspect)
    case "$*" in
      *State.Running*) echo true ;;
      *) seq="$STUB_ROOT/health.seq"
         [ -f "$seq" ] || printf '%s' "${STUB_HEALTH_SEQ:-healthy}" > "$seq"
         read -r first rest < "$seq"
         if [ -n "$rest" ]; then printf '%s' "$rest" > "$seq"; else printf '%s' "$first" > "$seq"; fi
         echo "$first" ;;
    esac ;;
  compose)
    case "$*" in
      *psql*) printf '%s\n' "$STUB_PGVER" ;;
      *" ps "*) echo cid-test ;;
      *" up "*) [ -z "${STUB_UP_FAIL:-}" ] || exit 1 ;;
      *) ;;
    esac ;;
  *) exit 1 ;;
esac
DOCKER_END
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logger.log"\n' "$ROOT" > "$STUBS/logger"
  cat > "$STUBS/deploy-recorder" <<'REC_END'
#!/usr/bin/env bash
# stand-in for odoosync-deploy: records its arguments; STUB_DEPLOY_RC sets the exit code; STUB_DEPLOY_BUSY prints the busy refusal
printf '%s\n' "$*" >> "$STUB_ROOT/deploy.calls"
[ -z "${STUB_DEPLOY_BUSY:-}" ] || { echo "deploy_refused busy" >&2; exit 3; }
exit "${STUB_DEPLOY_RC:-0}"
REC_END
  chmod +x "$STUBS/cosign" "$STUBS/docker" "$STUBS/logger" "$STUBS/deploy-recorder"
}

request() {  # request <service> <digest> <ref> [extra args]
  local s="$1" d="$2" r="$3"; shift 3
  run "$SCRIPTS/odoosync-deploy" request --env /etc/odoosync/env --service "$s" --digest "$d" --ref "$r" --check-only "$@"
}

apply() {  # apply <service> <digest> <ref> [extra args]   (the real thing: no --check-only)
  local s="$1" d="$2" r="$3"; shift 3
  run "$SCRIPTS/odoosync-deploy" request --env /etc/odoosync/env --service "$s" --digest "$d" --ref "$r" "$@"
}
D3="sha256:$(printf 'c%.0s' $(seq 64))"
