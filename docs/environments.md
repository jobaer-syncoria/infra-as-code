# Environments (non-secret outputs)

One section per environment. Only non-secret values: names, IDs, regions, public IPs, bucket names, firewall names.
Never a token, key, password or connection string.

## staging (S' `odoosync-stg-01`)
| Item | Value | Source |
|---|---|---|
| Droplet | _filled after PI.11_ | terraform output |
| VPC | `odoosync-stg-tor1` (PROPOSED) | ADR-09 r3 3.4 |
| pgdata volume | `odoosync-pgdata-stg` | ADR-11 3.1 |

## production (N, droplet 343876780)
| Item | Value | Source |
|---|---|---|
| Droplet | 343876780 | runbook PI.3 |
| VPC | default-tor1 `39a20e69-dc7f-11e8-b1a9-3cfdfea9ee58` (read only) | PI.3 |
| pgdata volume | `odoosync-pgdata-prod` | ADR-11 3.1 |
