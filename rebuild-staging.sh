#!/usr/bin/env bash
# Run on YOUR PC after the droplet was (re)built. Packs the three app repos, copies them and this repo to the server and
# runs the Ansible rebuild there.
#   ./rebuild-staging.sh <server-ip> [path-to-ssh-private-key]
# Login user: SSH_USER=root (default; needs your key in /root/.ssh/authorized_keys)
#             SSH_USER=syncoria-dev   no root SSH needed: files go to the user's home and the last step runs `sudo`
#                                     (you type the sudo password once, in your own terminal)
# Optional: DB_DUMP=/path/to/omnisync.dump        restore that database dump (pg_dump -Fc or plain SQL)
# Optional: CLOVER_DB_URL='mongodb+srv://...'      use that cloud Mongo (Atlas) instead of the local mongo container. The URL is
#           sent over SSH into a 0600 file on the server; it is never printed or put in the repo.
# Optional: ANSIBLE_ARGS='-e clover_deploy_env=production -e clover_production_db_host=<atlas-host>'   extra Ansible settings
# Ansible asks for an omnisync admin and a Clover admin password only when there is nothing to restore (no DB_DUMP / no CLOVER_DB_URL).
set -euo pipefail
IP="${1:?usage: ./rebuild-staging.sh <server-ip> [ssh-key]}"
KEY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_="${SSH_USER:-root}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
[ -z "$KEY" ] || SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
R="$USER_@$IP"
if [ "$USER_" = root ]; then BASE=/root; ASUDO=""; BUNDLES=/opt/odoosync-bundles; RESTORE=/opt/odoosync-restore; SECRETS=/opt/odoosync-secrets
else BASE="/home/$USER_"; ASUDO="sudo "; BUNDLES="$BASE/odoosync-bundles"; RESTORE="$BASE/odoosync-restore"; SECRETS="$BASE/odoosync-secrets"; fi
INFRA="$BASE/odoosync-infra"
EXTRA="-e code_bundle_dir=$BUNDLES -e db_restore_file=$RESTORE/omnisync.dump -e clover_db_url_file=$SECRETS/clover_db_url"
# The admin-password prompts only make sense on empty databases: a restored dump already holds its users, and a cloud Mongo
# already holds Clover's. Passing the variables (empty) tells Ansible not to ask.
[ -z "${DB_DUMP:-}" ] || EXTRA="$EXTRA -e omnisync_admin_password="
[ -z "${CLOVER_DB_URL:-}" ] || EXTRA="$EXTRA -e clover_admin_password="

echo "== 1/4 forget the old host key (a rebuilt server has a new one)"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true

echo "== 2/4 pack the app repos into bundles"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$HERE/scripts/make-bundles.sh" "$TMP/bundles"

echo "== 3/4 copy the bundles and the infra code to the server ($R)"
ssh "${SSH_OPTS[@]}" "$R" "mkdir -p '$BUNDLES' '$INFRA'"
tar -C "$TMP/bundles" -cf - . | ssh "${SSH_OPTS[@]}" "$R" "tar -C '$BUNDLES' -xf -"
tar -C "$HERE" --exclude=.git --exclude=collections --exclude=__pycache__ -cf - ansible scripts | ssh "${SSH_OPTS[@]}" "$R" "tar -C '$INFRA' -xf -"

if [ -n "${DB_DUMP:-}" ]; then
  [ -f "$DB_DUMP" ] || { echo "DB_DUMP not found: $DB_DUMP" >&2; exit 1; }
  echo "== 3b/4 upload the database dump ($(du -h "$DB_DUMP" | cut -f1))"
  ssh "${SSH_OPTS[@]}" "$R" "mkdir -p '$RESTORE' && chmod 700 '$RESTORE'"
  ssh "${SSH_OPTS[@]}" "$R" "cat > '$RESTORE/omnisync.dump' && chmod 600 '$RESTORE/omnisync.dump'" < "$DB_DUMP"
fi

if [ -n "${CLOVER_DB_URL:-}" ]; then
  echo "== 3c/4 upload the Clover database URL (not shown)"
  ssh "${SSH_OPTS[@]}" "$R" "mkdir -p '$SECRETS' && chmod 700 '$SECRETS'"
  printf '%s' "$CLOVER_DB_URL" | ssh "${SSH_OPTS[@]}" "$R" "cat > '$SECRETS/clover_db_url' && chmod 600 '$SECRETS/clover_db_url'"
fi

echo "== 4/4 run the rebuild on the server (the first run takes about 15 to 25 minutes)"
[ -z "$ASUDO" ] || echo "   sudo will ask for the password of $USER_ on the server."
exec ssh -t "${SSH_OPTS[@]}" "$R" "${ASUDO}bash '$INFRA/scripts/rebuild-staging.sh' $EXTRA ${ANSIBLE_ARGS:-}"
