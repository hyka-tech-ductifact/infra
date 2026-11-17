# Contributing

Create a branch from `main` and open a PR back into `main`. Use `feat/`, `fix/`,
or `chore/` branch names and matching conventional commit prefixes. Squash-merge
after CI passes.
Do not push directly to `main`; keep PRs focused on one change.

## Before opening a PR

```bash
./scripts/ci/check_repo.sh
```

Checks cover Compose, Prometheus, Grafana, shell scripts, and generated environment
files using dummy CI secrets. Requires Docker, `jq`, ShellCheck, and Python;
install PyYAML to include YAML provisioning checks.

Make shared config/image changes in `environments/`; personal local changes go
in the ignored `.env.local`. Never commit real staging/production credentials.

## Deploying changes

Validate changes in staging before promoting to production. Follow the
[deployment flow](README.md#deployment-flow); production promotions use a reviewed
PR with a new `RELEASE_VERSION`.

See [local setup](README.md#local-setup) to run the stack and the
[script guide](scripts/README.md) for individual commands.
