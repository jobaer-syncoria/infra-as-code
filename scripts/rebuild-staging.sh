#!/usr/bin/env bash
# Run ON THE SERVER as root, after a DigitalOcean rebuild, from the repo folder you copied there.
# Installs Ansible (pinned) into a virtual environment and runs the staging playbook on this machine.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash scripts/rebuild-staging.sh" >&2; exit 1; }
cd "$(dirname "$0")/../ansible"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq python3-venv python3-apt git >/dev/null
VENV=/opt/ansible-venv
[ -x "$VENV/bin/ansible-playbook" ] || { python3 -m venv --system-site-packages "$VENV"; "$VENV/bin/pip" install -q "ansible-core~=2.21.0"; }
"$VENV/bin/ansible-galaxy" collection install -r requirements.yml -p ./collections >/dev/null
exec "$VENV/bin/ansible-playbook" playbooks/site.yml "$@"
