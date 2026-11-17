# Infrastructure scripts

Run these examples from `infra/`. Folders group responsibilities: `ci/` contains
workflow entry points, `ops/` performs operations, and `checks/` verifies results.

## Commands

| Task | Command | Where |
|------|---------|-------|
| Generate local config | `./scripts/ops/generate_env.sh local` | Developer machine |
| Deploy | `./scripts/ops/deploy.sh local` | Machine running the containers |
| Stop services | `./scripts/ops/deploy.sh staging stop` | Target server |
| Validate a runtime file | `./scripts/checks/env.sh local` | Machine containing the file |
| Check service health | `./scripts/checks/health.sh staging` | Target server |
| Test the API journey | `./scripts/checks/user_flow.sh local fresh-test@example.com` | Machine running the containers |
| Check the repo | `./scripts/ci/check_repo.sh` | Developer machine or PR runner |

Environment arguments support `local`, `staging`, and `production`.
`ci/deploy_remote.sh` accepts staging/production only and runs in CI with secrets
and SSH access. See [maintenance](../MAINTENANCE.md#database-backups) for `ops/db.sh`.

## Automatic calls

```text
ci/check_repo.sh → ops/generate_env.sh → checks/env.sh
ci/deploy_remote.sh → ops/generate_env.sh → upload → SSH → ops/deploy.sh
ops/deploy.sh → checks/env.sh → deploy → checks/health.sh
```

`deploy.sh` includes validation and health checks, waits up to 120 seconds for
startup, and prints diagnostics on failure. Its `stop` action only stops services.
CI updates the server checkout; before a manual server update, run
`git pull --ff-only origin main` yourself. Deployment uses the installed runtime
file and does not regenerate it.

`user_flow.sh` runs only when explicitly invoked. Use a fresh email inbox you can
read: the script prompts for the registration code and cleans up its test resources
and account on exit. Reported cleanup failures may require manual cleanup.

## Generator options

- `--output PATH`: write somewhere other than `.env.<env>`.
- `--force`: replace the entire output file with the generation inputs.
- `checks/env.sh <env> --file PATH`: validate a file at a different location.

See [configuration](../README.md#configuration) for the inputs and final runtime files.
When changing `BACKEND_PORT` locally, update `PUBLIC_BACKEND_URL` and
`PUBLIC_FILE_STORAGE_URL` to match so the browser calls the correct API.
