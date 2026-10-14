#!/usr/bin/env bash
# Run by a RELEASE APPROVER, on their own PC, in a clone of the infra repo. Creates and pushes a SIGNED release tag.
#   scripts/make-release-tag.sh <tag> <ssh-key-file>
#     <tag>       release/YYYYMMDD-N   (for example release/20261015-1)
#     <ssh-key>   the key you sign with: the private key file, or its .pub when the key is loaded in your ssh-agent
# The servers accept a tag only when it is signed by a key listed in their allowed_signers AND reachable from the production
# branch, so this refuses to run anywhere else. Nothing is pushed until you type "yes".
set -euo pipefail
TAG="${1:?usage: make-release-tag.sh release/YYYYMMDD-N <ssh-key-file>}"
KEY="${2:?usage: make-release-tag.sh release/YYYYMMDD-N <ssh-key-file>}"
[[ "$TAG" =~ ^release/[0-9]{8}-[0-9]+$ ]] || { echo "the tag must look like release/20261015-1" >&2; exit 2; }
[ -f "$KEY" ] || { echo "key file not found: $KEY" >&2; exit 2; }
[ "$(git branch --show-current)" = production ] || { echo "switch to the production branch first" >&2; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "the working tree is not clean" >&2; exit 2; }
git fetch --quiet origin production
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/production)" ] || { echo "production is not up to date with origin/production" >&2; exit 2; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "the tag $TAG already exists" >&2; exit 2; }

echo "About to sign and push $TAG at commit $(git rev-parse --short HEAD): $(git log -1 --format=%s)"
read -r -p 'Type "yes" to continue: ' ANS
[ "$ANS" = yes ] || { echo "cancelled"; exit 1; }

# the message carries the checks odoosync-promote recorded (or the override reasons), so the signature covers them
MSG=(-m "release $TAG")
[ ! -s releases/promotion-notes.txt ] || MSG+=(-m "$(cat releases/promotion-notes.txt)")
git -c gpg.format=ssh -c "user.signingkey=$KEY" tag -s "${MSG[@]}" "$TAG"
# prove the signature verifies against the key we signed with, before anyone else sees the tag
SIGNERS="$(mktemp)"; trap 'rm -f "$SIGNERS"' EXIT
PUB="$KEY"; [[ "$KEY" == *.pub ]] || PUB="$KEY.pub"
printf 'approver namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$PUB")" > "$SIGNERS"
git -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$SIGNERS" verify-tag "$TAG" >/dev/null 2>&1 \
  || { git tag -d "$TAG" >/dev/null; echo "the signature did not verify, tag removed" >&2; exit 1; }
git push origin "refs/tags/$TAG"
echo "pushed $TAG (signature verified)"
