#!/usr/bin/env bash
# Run on YOUR PC. Packs the three app repos (at the branches staging runs) into git bundle files, so the rebuilt
# server needs no GitHub access. Usage: scripts/make-bundles.sh [output-dir]
#   Repo locations and branches can be overridden:  OMNISYNC=... ADMIN=... CLOVER=...
set -euo pipefail
OUT="${1:-./bundles}"
BASE="${CODEBASE:-$HOME/SyncoriaConnector_Handover_sfm/SyncoriaConnector_Handover/codebase}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # absolute, because verify runs inside each repo
make() {  # <dir> <branch> <file>
  local dir="$1" branch="$2" file="$3"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || { echo "not a git repo: $dir" >&2; exit 1; }
  git -C "$dir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || { echo "branch $branch not found in $dir" >&2; exit 1; }
  git -C "$dir" bundle create "$OUT/$file" "$branch" >/dev/null 2>&1
  git -C "$dir" bundle verify "$OUT/$file" >/dev/null 2>&1 || { echo "bundle $file did not verify" >&2; exit 1; }
  echo "ok  $file  ($branch @ $(git -C "$dir" rev-parse --short "$branch"))"
}
make "${OMNISYNC:-$BASE/omnisync}"              "${OMNISYNC_BRANCH:-ci/omnisync-image-contract}"   omnisync.bundle
make "${ADMIN:-$BASE/syncoria-connector-admin}" "${ADMIN_BRANCH:-ci/admin-release}"                admin.bundle
make "${CLOVER:-$BASE/odoo-clover-cloud-ns}"    "${CLOVER_BRANCH:-fix/ns-outbound-and-broken}"     clover.bundle
echo "Bundles are in $OUT. Copy them to the server (docs/runbooks/rebuild-staging.md, step 3)."
