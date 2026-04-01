# Contributing Guide

## Workflow overview

Changes to infrastructure are deployed **manually** after merge — staging first, then production.

There is no CD pipeline for this repo. This is intentional: infra changes (image upgrades, config tweaks) are infrequent and high-impact, so a human should always be watching.

---

## 1) Branches

| Prefix | Purpose | Example |
|--------|---------|---------|
| `feat/` | New services, dashboards, alerts | `feat/add-redis` |
| `fix/` | Fix broken config, wrong ports | `fix/prometheus-scrape-interval` |
| `chore/` | Version bumps, CI, docs, cleanup | `chore/upgrade-grafana-12` |

All PRs target `main`. There is no `release` branch — production is updated manually.

---

## 2) Day-to-day workflow

```bash
git checkout main && git pull
git checkout -b chore/upgrade-prometheus

# edit, commit, push
git push -u origin chore/upgrade-prometheus
```

Open a PR into `main`. CI validates compose syntax, Prometheus config, Grafana dashboards, and deploy script.

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
- Test in staging before applying to production
