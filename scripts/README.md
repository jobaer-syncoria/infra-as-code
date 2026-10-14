# scripts/

Root tools for the servers (runbook PI.5). They are installed by Ansible into `/usr/local/sbin`, never run from a checkout.

| Tool | Status | What |
|---|---|---|
| `odoosync-deploy request` | **slices 1 and 2** | Every guard of ADR-08 3.9: argument grammar, DEPLOY_FREEZE, signed release tag reachable from `production`, image from the fixed list with a cosign identity bound to the repo's `release.yml` on `refs/heads/production`, production digest named in the signed `releases/production.json`, production label matrix (Python >= 3.12, Django >= 5.2), `serving_values.json` byte-equal to the infra copy, PostgreSQL >= 14, tier1-baseline override (one digest, never after `E1_FINAL`). Slice 2 adds: missing-secret guard, image-by-environment guard, clover-node environment guard; then the **apply**: pull by digest, recreate ONLY that service (`up -d --no-deps --force-recreate`, grace from the compose file, never a literal `-t`), wait healthy, automatic rollback to the previous release (exit 4), a deploy lock, and a release log. **Production refuses services on the payment path** (`apply_needs_bluegreen`) until blue/green exists. |
| `odoosync-deploy rollback`, `stop`, `flag set\|unset DEPLOY_FREEZE` | **done** (slice 2) | rollback re-runs every guard on the older release; flags: only DEPLOY_FREEZE, which recreates nothing |
| `odoosync-secrets` | done | `set` (one line, no echo, never argv, atomic 0600), `check` (set/empty/missing), `hs256-check` (prints only `verifies true/false` and a length) |
| `make-release-tag.sh` | done | for a release approver: creates, verifies and pushes a signed `release/YYYYMMDD-N` tag (refuses off `production`, dirty tree, stale branch) |
| `check-versions` | done (PI.2) | pins in the repo match `VERSIONS.md` |
| `make-bundles.sh`, `rebuild-staging.sh` | done | staging rebuild helpers (not part of the root toolset) |
| zero-drop blue/green for web and web-terminal, the Clover drain (CCD), other flags, scheduled jobs | **not built** | needs the colour layout of the compose file (PI.4) |
| `odoosync-pull`, `odoosync-promote` | **not built** | |
| `odoosync-verify`, `cert-bootstrap.sh`, `memwatch` | **not built** | |
| database tools: `odoosync-pgdata-init`, `db-bootstrap`, `pgbackup`, WAL-G wrappers, `pgwatch`, `restore-test.sh`, `pmove-dump`, `pmove-restore` | **not built** | |

## Tests
`scripts/tests/*.bats` (79 cases: INFRA-DEP-04 guards, INFRA-DEP-05 trust chain, the apply/rollback/stop/flag/lock/secret/clover cases, and the secrets tool). They build a throwaway sandbox
(a real git repo with real SSH-signed tags, a trust folder, stand-ins for `cosign`, `docker` and `logger`) and must run as a **non-root**
user: the tools honour `ODOOSYNC_TEST_ROOT` only when `uid != 0`, so a root run can never be redirected by the environment.
```bash
sudo apt-get install -y bats git jq openssh-client python3   # then:
bats scripts/tests
```

## Files the deploy tool keeps (root only)
- `/srv/odoosync/state/images.env`: `IMAGE_<SERVICE>=repo@digest`, read by compose through `--env-file`; the compose file itself comes from the verified release tree.
- `/srv/odoosync/state/releases.jsonl`: one line per deploy (`ok`, `failed`, `rolled_back`, `stopped`) with the operator; rollback reads it.
- `/srv/odoosync/state/deploy.lock`: one deploy at a time.
- Signed policy keys (`image-policy.json`): `services`, `upstream`, `images`, `label_checked`, `required_secrets`, `deny_repos`, `clover_env_file`, `readiness_timeout`, `poll_seconds`, `stable_seconds`.

## Trust rules the tools enforce
- A file that a non-root user can write (group/other write bit, a symlink, wrong owner) is never read as trusted input.
- A secret is never an argument, never printed, never logged. Refusals print names, digests and tag names only.
- Every refusal is one line, `deploy_refused <reason> [names]`, to stderr and the journal, exit 3.

## Installation
The Ansible role `deploy_tools` installs `odoosync-deploy` and `odoosync-secrets` under `/usr/local/lib/odoosync` (links in `/usr/local/sbin`), pins cosign by version and sha256, writes `/etc/odoosync/{env,flags.env,trust/*}` and clones the infra repo to `/srv/odoosync/infra.git`. It installs nothing until an approver public key is given. See `docs/runbooks/staging-deploy.md`.
