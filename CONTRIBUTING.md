# Contributing Guide

## Workflow overview

This repo **has no versions and no CD pipeline**. Each change is deployed manually after merge — staging first, then production.

This is intentional: infra changes (image upgrades, config tweaks) are infrequent and high-impact, so a human should always be in control.

---

## 1) Branches

| Prefix | Purpose | Example |
|--------|---------|---------|
| `feat/` | New services, dashboards, alerts | `feat/add-redis` |
| `fix/` | Fix broken config, wrong ports | `fix/prometheus-scrape-interval` |
| `chore/` | Version bumps, CI, docs, cleanup | `chore/upgrade-grafana-12` |

All PRs target `main`. There are no releases, tags, or versions — `main` is always the source of truth and production is updated manually.

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

## 3) Deploy (after merge)

```bash
# SSH to the server
ssh deploy@your-server

cd ~/ductifact/infra
git pull

# Always staging first
docker compose --env-file .env.staging up -d
# Verify: check logs, health endpoints, Grafana

# Then production
docker compose --env-file .env.prod up -d
# Verify again
```

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
