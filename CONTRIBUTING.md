# Contributing Guide

## Workflow overview

Staging deploys through CI when its configured inputs change on `main`. Production promotions require a reviewed PR and create a release after deployment. See [README.md](README.md#environment-files-and-deployment) for the generation and deployment flow.

---

## 1) Branches

| Prefix | Purpose | Example |
|--------|---------|---------|
| `feat/` | New services, dashboards, alerts | `feat/add-redis` |
| `fix/` | Fix broken config, wrong ports | `fix/prometheus-scrape-interval` |
| `chore/` | Version bumps, CI, docs, cleanup | `chore/upgrade-grafana-12` |

All PRs target `main`. Application promotions are declared in environment manifests; successful production deployments create tags and releases.

---

## 2) Day-to-day workflow

```bash
git checkout main && git pull
git checkout -b chore/upgrade-prometheus

# edit, commit, push
git push -u origin chore/upgrade-prometheus
```

Open a PR into `main`. Use **squash merge** (1 PR = 1 commit).

CI validates compose syntax, Prometheus config, Grafana dashboards, and deploy script.

---

## 3) Generate and deploy environments

Make persistent configuration/image changes in `environments/`. CI combines those
inputs with GitHub Environment secrets using `scripts/ops/generate_env.sh`, copies the
final `.env.staging` or `.env.production` to the server, then runs `deploy.sh`.
Deploy staging first and validate it before promoting to production.

For local testing, build the images named in `environments/local.manifest.env`,
then run:

```bash
./scripts/ops/generate_env.sh local
./scripts/ops/deploy.sh local
```

Edit `.env.local` directly for personal settings. It is ignored by Git, and
`deploy.sh` does not regenerate it. `generate_env.sh local --force` explicitly
replaces the entire file with the versioned development defaults.
`deploy.sh` only consumes the final `.env.<environment>`.
See [local setup](README.md#local-deployment) for image builds and SMTP setup.

Run `./scripts/ci/check_repo.sh` before pushing. It generates and validates all
three environment files with dummy CI secrets, without deploying.

---

## 4) Commit messages

[Conventional Commits](https://www.conventionalcommits.org/):

`feat:`, `fix:`, `chore:`

---

## 5) PR rules

- No direct pushes to `main`
- CI must pass (compose validation, prometheus config, shellcheck)
- Keep PRs small and focused
- Test in staging before applying to production
