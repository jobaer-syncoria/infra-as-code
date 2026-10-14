# scripts/

Root tools for the servers (runbook PI.5). They are installed by Ansible into `/usr/local/sbin`, never run from a checkout.

| Tool | Status | What |
|---|---|---|
| `odoosync-deploy request` | **slice 1: guards only** | Every guard of ADR-08 3.9: argument grammar, DEPLOY_FREEZE, signed release tag reachable from `production`, image from the fixed list with a cosign identity bound to the repo's `release.yml` on `refs/heads/production`, production digest named in the signed `releases/production.json`, production label matrix (Python >= 3.12, Django >= 5.2), `serving_values.json` byte-equal to the infra copy, PostgreSQL >= 14, tier1-baseline override (one digest, never after `E1_FINAL`). After the guards it exits **78: apply not implemented**. |
| `odoosync-secrets` | done | `set` (one line, no echo, never argv, atomic 0600), `check` (set/empty/missing), `hs256-check` (prints only `verifies true/false` and a length) |
| `check-versions` | done (PI.2) | pins in the repo match `VERSIONS.md` |
| `make-bundles.sh`, `rebuild-staging.sh` | done | staging rebuild helpers (not part of the root toolset) |
| `odoosync-deploy` apply (blue/green, recreate, CCD, rollback, flags, jobs, stop) | **not built** | next slice |
| `odoosync-pull`, `odoosync-promote` | **not built** | |
| `odoosync-verify`, `cert-bootstrap.sh`, `memwatch` | **not built** | |
| database tools: `odoosync-pgdata-init`, `db-bootstrap`, `pgbackup`, WAL-G wrappers, `pgwatch`, `restore-test.sh`, `pmove-dump`, `pmove-restore` | **not built** | |

## Tests
`scripts/tests/*.bats` (48 cases: INFRA-DEP-04 guards, INFRA-DEP-05 trust chain, and the secrets tool). They build a throwaway sandbox
(a real git repo with real SSH-signed tags, a trust folder, stand-ins for `cosign`, `docker` and `logger`) and must run as a **non-root**
user: the tools honour `ODOOSYNC_TEST_ROOT` only when `uid != 0`, so a root run can never be redirected by the environment.
```bash
sudo apt-get install -y bats git jq openssh-client python3   # then:
bats scripts/tests
```

## Trust rules the tools enforce
- A file that a non-root user can write (group/other write bit, a symlink, wrong owner) is never read as trusted input.
- A secret is never an argument, never printed, never logged. Refusals print names, digests and tag names only.
- Every refusal is one line, `deploy_refused <reason> [names]`, to stderr and the journal, exit 3.
