# shellcheck shell=bash
# shellcheck disable=SC2034   # the OS_* paths are used by the scripts that source this file
# Shared helpers for the odoosync root tools. Sourced, never executed.
#
# SAFETY: a root tool must not honour environment overrides, because `sudo` can pass them on. The sandbox mode used by the
# bats tests is therefore available ONLY when the caller is NOT root (uid != 0) and ODOOSYNC_TEST_ROOT is set. As root the
# paths below are fixed.

if [ "$(id -u)" -ne 0 ] && [ -n "${ODOOSYNC_TEST_ROOT:-}" ]; then
  OS_TEST=1
  OS_ETC="$ODOOSYNC_TEST_ROOT/etc/odoosync"
  OS_SRV="$ODOOSYNC_TEST_ROOT/srv/odoosync"
else
  OS_TEST=0
  OS_ETC=/etc/odoosync
  OS_SRV=/srv/odoosync
fi
OS_TRUST="$OS_ETC/trust"
OS_STATE="$OS_SRV/state"
OS_RELEASES="$OS_SRV/releases"
OS_BARE="$OS_SRV/infra.git"          # root-owned bare clone of the infra repo (read-only deploy key)
OS_PROD_REF="refs/heads/production"  # a release tag must be reachable from this branch

log() { printf '%s\n' "$*" >&2; }

# Machine-readable refusal: one line `deploy_refused <reason> [names only]` to stderr and the journal, exit 3.
# Never put a secret, a token or a file content in the detail: names, digests and tag names only.
refuse() {
  local reason="$1"; shift || true
  local line="deploy_refused ${reason}${*:+ $*}"
  printf '%s\n' "$line" >&2
  logger -t odoosync-deploy -p auth.notice -- "$line" 2>/dev/null || true
  exit 3
}

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# A file a non-root user can write must never be read as trusted input.
# Real run: owned by root and not writable by group or others. Sandbox: the mode check only.
trust_file_ok() {
  local f="$1" mode
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  mode="$(stat -c '%a' "$f")"
  [ $(( 8#$mode & 8#022 )) -eq 0 ] || return 1
  if [ "$OS_TEST" -eq 0 ]; then [ "$(stat -c '%u' "$f")" -eq 0 ] || return 1; fi
  return 0
}

# true when $1 >= $2, both dotted versions (3.12.4 >= 3.12)
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
