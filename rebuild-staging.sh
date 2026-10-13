#!/usr/bin/env bash
# Run on YOUR PC, after you clicked "Rebuild" in the DigitalOcean console (Ubuntu 24.04, your SSH key selected).
#   ./rebuild-staging.sh <server-ip> [path-to-ssh-private-key]
# It packs the three app repos, copies them and this repo to the server, and runs the Ansible rebuild there.
# Optional: DB_DUMP=/path/to/omnisync.dump ./rebuild-staging.sh <ip>   restores that database dump (pg_dump -Fc or plain SQL).
# You are asked for two passwords at the end of the start-up (omnisync admin, Clover Cloud admin); Enter skips one.
set -euo pipefail
IP="${1:?usage: ./rebuild-staging.sh <server-ip> [ssh-key]}"
KEY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
[ -z "$KEY" ] || SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
R="root@$IP"

echo "== 1/4 forget the old host key (a rebuilt server has a new one)"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true

echo "== 2/4 pack the app repos into bundles"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$HERE/scripts/make-bundles.sh" "$TMP/bundles"

echo "== 3/4 copy the bundles and the infra code to the server"
ssh "${SSH_OPTS[@]}" "$R" 'mkdir -p /opt/odoosync-bundles /root/odoosync-infra'
tar -C "$TMP/bundles" -cf - . | ssh "${SSH_OPTS[@]}" "$R" 'tar -C /opt/odoosync-bundles -xf -'
tar -C "$HERE" --exclude=.git --exclude=collections --exclude=__pycache__ -cf - ansible scripts | ssh "${SSH_OPTS[@]}" "$R" 'tar -C /root/odoosync-infra -xf -'

if [ -n "${DB_DUMP:-}" ]; then
  [ -f "$DB_DUMP" ] || { echo "DB_DUMP not found: $DB_DUMP" >&2; exit 1; }
  echo "== 3b/4 upload the database dump ($(du -h "$DB_DUMP" | cut -f1))"
  ssh "${SSH_OPTS[@]}" "$R" 'mkdir -p /opt/odoosync-restore && chmod 700 /opt/odoosync-restore'
  ssh "${SSH_OPTS[@]}" "$R" 'cat > /opt/odoosync-restore/omnisync.dump && chmod 600 /opt/odoosync-restore/omnisync.dump' < "$DB_DUMP"
fi

echo "== 4/4 run the rebuild on the server (the first run takes about 15 to 25 minutes)"
exec ssh -t "${SSH_OPTS[@]}" "$R" 'bash /root/odoosync-infra/scripts/rebuild-staging.sh'
