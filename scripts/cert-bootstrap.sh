#!/usr/bin/env bash
# cert-bootstrap.sh: issue the first Let's Encrypt certificates on a new server (ADR-08 3.6). Run as root, once, after `edge`
# is up and the names point at this server. certbot owns renewals afterwards.
#   cert-bootstrap.sh [--dry-run]
# What it does, from the signed policy's `certs` block ({"email": "...", "certs": {"<cert-name>": ["<domain>", ...]}}):
#   1. refuses unless certbot is installed, the policy names certs and a real contact email, and every domain serves a probe file
#      from /srv/certbot/www over plain HTTP (so DNS and the edge are right before Let's Encrypt is asked: no wasted attempts);
#   2. installs the deploy hook that reloads nginx inside `edge` after each renewal;
#   3. runs `certbot certonly --webroot` once per certificate, separately, so one failure cannot take the others down;
#   4. checks the private keys are root-only and prints each certificate's notAfter date.
# Safe to run again: certificates that are not near expiry are kept. --dry-run uses Let's Encrypt's test servers and saves nothing.
# Output never contains a key or a token. Exit 0 when every certificate is in place, 1 otherwise, 2 for bad use.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
. "$HERE/lib/common.sh"

RFS=""; if [ "$OS_TEST" -eq 1 ]; then RFS="$ODOOSYNC_TEST_ROOT/rootfs"; fi
LE="$RFS/etc/letsencrypt"; WEBROOT="$RFS/srv/certbot/www"
POLICY="$OS_TRUST/image-policy.json"; ENV_FILE="$OS_ETC/env"

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: cert-bootstrap.sh [--dry-run]" >&2; exit 2 ;;
esac

stop() { printf 'cert_refused %s\n' "$*" >&2; exit 3; }
need jq; need curl; need openssl
command -v certbot >/dev/null 2>&1 || stop no_certbot "install the certbot snap first"
trust_file_ok "$POLICY" || stop trust_file_unsafe image-policy.json
trust_file_ok "$ENV_FILE" || stop trust_file_unsafe env

EMAIL="$(jq -r '.certs.email // empty' "$POLICY")"
case "$EMAIL" in ""|*CHANGE-ME*) stop no_contact_email "set certs.email in the policy" ;; esac
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || stop bad_contact_email
mapfile -t NAMES < <(jq -r '(.certs.certs // {}) | keys[]' "$POLICY")
[ "${#NAMES[@]}" -gt 0 ] || stop no_certs "the policy lists no certs"
for n in "${NAMES[@]}"; do
  [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || stop bad_cert_name "$n"
  while read -r d; do [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || stop bad_domain "$d"; done < <(jq -r ".certs.certs[\"$n\"][]" "$POLICY")
done
PROJECT="$(sed -n 's/^OMNISYNC_COMPOSE_PROJECT=//p' "$ENV_FILE" | head -n1)"; PROJECT="${PROJECT:-omnisync}"

# 1. the probe: DNS and the edge must already serve /.well-known/acme-challenge/ from the webroot
mkdir -p "$WEBROOT/.well-known/acme-challenge"; chmod 755 "$WEBROOT" "$WEBROOT/.well-known" "$WEBROOT/.well-known/acme-challenge"
TOKEN="probe-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
PROBE="$WEBROOT/.well-known/acme-challenge/$TOKEN"
ERR="$(mktemp)"   # certbot's stderr: kept out of the public webroot
trap 'rm -f "$PROBE" "$ERR"' EXIT
printf '%s' "$TOKEN" > "$PROBE"; chmod 644 "$PROBE"
bad=0
for n in "${NAMES[@]}"; do
  while read -r d; do
    got="$(curl -fsS --max-time 10 "http://$d/.well-known/acme-challenge/$TOKEN" 2>/dev/null)"
    if [ "$got" = "$TOKEN" ]; then echo "PASS probe $d"; else echo "FAIL probe $d (DNS not pointing here, or edge not serving the challenge folder)"; bad=1; fi
  done < <(jq -r ".certs.certs[\"$n\"][]" "$POLICY")
done
[ "$bad" -eq 0 ] || stop probe_failed "fix DNS or the edge, then rerun"

# 2. the deploy hook: reload nginx in edge after every renewal
HOOK_DIR="$LE/renewal-hooks/deploy"; HOOK="$HOOK_DIR/odoosync-edge-reload"
mkdir -p "$HOOK_DIR"
cat > "$HOOK.new" <<HOOK_END
#!/usr/bin/env bash
# written by cert-bootstrap.sh: reload nginx inside edge so it picks up the renewed certificate
cid="\$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=edge" | head -n1)"
[ -n "\$cid" ] || { echo "edge container not found" >&2; exit 1; }
exec docker exec "\$cid" nginx -s reload
HOOK_END
chmod 755 "$HOOK.new"; mv "$HOOK.new" "$HOOK"
echo "PASS deploy_hook $HOOK"

# 3. one certbot run per certificate
FAILED=0
for n in "${NAMES[@]}"; do
  args=(certonly --webroot -w "$WEBROOT" --cert-name "$n" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring --deploy-hook "$HOOK")
  while read -r d; do args+=(-d "$d"); done < <(jq -r ".certs.certs[\"$n\"][]" "$POLICY")
  [ "$DRY" -eq 0 ] || args+=(--dry-run)
  if certbot "${args[@]}" >/dev/null 2>"$ERR"; then
    echo "PASS cert $n"
  else
    echo "FAIL cert $n: $(head -n1 "$ERR" | cut -c1-200)"; FAILED=$((FAILED + 1))
  fi
done

# 4. key permissions and expiry dates (a dry run saves nothing, so there is nothing to check)
if [ "$DRY" -eq 0 ]; then
  for n in "${NAMES[@]}"; do
    key="$LE/live/$n/privkey.pem"; crt="$LE/live/$n/fullchain.pem"
    if [ ! -e "$key" ]; then echo "FAIL key $n missing"; FAILED=$((FAILED + 1)); continue; fi
    mode="$(stat -L -c '%a' "$key")"
    if [ $(( 8#$mode & 8#077 )) -eq 0 ]; then echo "PASS key_mode $n $mode"; else echo "FAIL key_mode $n $mode (must not be group or world accessible)"; FAILED=$((FAILED + 1)); fi
    echo "INFO notAfter $n $(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | sed 's/^notAfter=//')"
  done
fi

if [ "$FAILED" -eq 0 ]; then echo "cert_bootstrap_ok"; exit 0; else echo "cert_bootstrap_failed $FAILED"; exit 1; fi
