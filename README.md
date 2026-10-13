# odoosync-infra

Infrastructure as code for the SyncoriaConnector platform: Terraform, Ansible, compose, nginx, deploy scripts.
Layout and rules: ADR-08 section 3.14. Version pins: [VERSIONS.md](VERSIONS.md) (machine-checked).

**Status: PI.2 scaffold only.** The tree and CI exist; the content arrives in later runbook steps.

| Step | Adds |
|---|---|
| PI.3 | `terraform/` modules and the four states (staging, production, production-edge, production-drills) |
| PI.4 | `compose/`, `nginx/`, `images/postgres/`, `compose/postgres/` |
| PI.5 | the deploy, secrets, verify, backup and move scripts |
| PI.6 | Ansible roles and `bootstrap.yml` |
| PI.7 | `templates.yml`, runbooks |

## Rules
- No secret in this repo, ever. CI holds none and never runs `terraform plan` or `apply`; a human runs them and pastes the plan into the PR.
- Nothing is based on `main`. The default branch is `production`.
- Every pin must match VERSIONS.md (`scripts/check-versions`).

## CI (`.github/workflows/ci.yml`)
| Job | What |
|---|---|
| terraform (INFRA-CI-01) | fmt, validate, tflint, `trivy config`, lifecycle policy (`ci/check_terraform_policy.py`) |
| ansible (INFRA-CI-02) | ansible-lint, molecule |
| shell (INFRA-CI-03) | shellcheck, bats |
| compose-nginx (INFRA-CI-04) | `compose config -q`, `nginx -t` per variant |
| invariants (INFRA-CI-05) | check self-test, no project-wide `up -d`, no literal `-t`, INFRA-PG-11-01/02, one base digest, windows never overlap |
| versions (INFRA-CI-06) | `scripts/check-versions` |
| gitleaks (INFRA-CI-07) | secrets scan of the full history |

Run the checks locally: `pip install pyyaml && bash ci/tests/run.sh && python3 scripts/check-versions`.

## Not done yet (be honest about the gaps)
- The CI job names INFRA-CI-01..07 are this scaffold's grouping; the ADR does not number the jobs, so re-map them if the ADRs do.
- Not yet implemented, named as TODO in `ci.yml`: ADR-04 C-04-05 symbols check, ADR-05 UT-CUT-01, ADR-01 UT-RT-01, the trusted-proxy name check.
- `nginx -t` per variant and molecule scenarios arrive with PI.4 and PI.6.
- Image and binary digests in VERSIONS.md are `UNRESOLVED` until the file that uses them is written.
- The workflow has not run on GitHub yet.
