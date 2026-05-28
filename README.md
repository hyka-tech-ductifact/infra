# Ductifact — Infrastructure

Infrastructure configuration for the **production** and **staging** environments of Ductifact.

This repo is cloned on the server (`~/ductifact/infra/`) and contains everything needed to orchestrate services with Docker Compose.

**This repo is the source of truth for production deployments** — merging changes to `environments/production.manifest.env` triggers a deploy.

## Project Structure

```
├── .github/workflows/
│   ├── ci.yml                   # CI: validates compose + prometheus configs
│   ├── cd-staging.yml           # Updates staging manifest + deploys staging on image-published
│   ├── cd-production.yml        # CD: deploys to production when manifest changes
├── docker-compose.yml           # Production/staging compose (single source of truth)
├── environments/
│   ├── local.manifest.env       # Local manifest (image versions)
│   ├── production.manifest.env  # 🎯 Production manifest (image versions)
│   └── staging.manifest.env     # Staging manifest (image versions)
├── .env.prod.example            # Production environment variables template (secrets)
├── .env.staging.example         # Staging environment variables template (secrets)
├── .env.local.example           # Local development environment variables template
├── observability/               # Prometheus + Grafana configuration
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── alerts.yml
│   └── grafana/
│       ├── provisioning/
│       └── dashboards/
└── scripts/
    ├── deploy.sh                # Deploy script (reads manifest + .env for config)
    ├── smoke.sh                 # Post-deploy health checks
    └── validate.sh              # Pre-deploy validation
```

## Deployment Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ STAGING (automatic)                                               │
│                                                                   │
│ Merge to main → CI ✅ → Build image → Push to GHCR               │
│                        → SSH to server → deploy.sh staging        │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ PRODUCTION (semi-automatic via GitOps)                            │
│                                                                   │
│ 1. CI on main builds immutable images (sha-<gitsha>)             │
│ 2. cd-staging.yml auto-updates staging and deploys               │
│ 3. Human validates in staging                                    │
│ 4. Human opens PR editing environments/production.manifest.env   │
│ 5. Human reviews + approves + merges the PR                      │
│ 6. cd-production.yml triggers → SSH to server → deploy.sh prod   │
└──────────────────────────────────────────────────────────────────┘
```

### Promoting to Production

**Manual:** Edit `environments/production.manifest.env` directly and open a PR:

```bash
# Update backend to a tested immutable image
sed -i 's|^BACKEND_IMAGE=.*|BACKEND_IMAGE=ghcr.io/hyka-tech-ductifact/backend:sha-abc1234|' environments/production.manifest.env

# Update both services at once
git checkout -b promote/release-2026-05-20
git add environments/production.manifest.env
git commit -m "promote: backend sha-abc1234 + frontend sha-def5678"
git push origin promote/release-2026-05-20
# → Open PR → Review → Merge → Auto-deploy
```

### Production Versioning (Tags & Releases)

- Every successful production deploy creates a git tag + GitHub Release in this repo.
- Default behavior (push trigger): auto-bump patch version (`vX.Y.Z` → `vX.Y.(Z+1)`).
- Manual deploy (`workflow_dispatch`): you can provide `version` (example: `v0.5.0`).
- Release notes include deployed backend/frontend image refs from `environments/production.manifest.env`.

### Rollback

```bash
# Revert the last promotion commit
git revert HEAD
git push origin main
# → cd-production.yml triggers → deploys the previous versions
```

## Setup

```bash
# 1. Clone on the server
git clone https://github.com/hyka-tech-ductifact/infra.git ~/ductifact/infra
cd ~/ductifact/infra

# 2. Create .env files from the examples
cp .env.prod.example .env.prod
cp .env.staging.example .env.staging
# Edit both with real values (passwords, JWT, etc.)

# 3. Log in to ghcr.io
echo "YOUR_GITHUB_TOKEN" | docker login ghcr.io -u YOUR_USER --password-stdin

# 4. Start the environments
./scripts/deploy.sh staging
./scripts/deploy.sh prod
```

## Required Secrets (GitHub)

| Secret | Used by | Purpose |
|--------|---------|---------|
| `VPS_SSH_KEY` | cd-production.yml | SSH key for server access |
| `VPS_USER` | cd-production.yml | Server username |
| `VPS_HOST` | cd-production.yml | Server hostname (Cloudflare Tunnel) |
| `CF_ACCESS_CLIENT_ID` | cd-production.yml | Cloudflare Access service token ID |
| `CF_ACCESS_CLIENT_SECRET` | cd-production.yml | Cloudflare Access service token secret |
| `INFRA_PAT` | backend/frontend repos | PAT with `repo` scope to dispatch events to this repo |

## Notes

- `.env.prod`, `.env.staging`, and `.env.local` are **never committed** (listed in `.gitignore`).
- `environments/production.manifest.env` **is committed** — it only contains image references, no secrets.
- Staging and production use **different credentials** (DB, JWT).
- Ports are only exposed on `127.0.0.1` — Caddy (host-level) handles reverse proxying.
- Full CD guide available at `backend/docs/GUIDE_CD.md`.
- Server maintenance (logs, backups, rollbacks, security) documented in [`MAINTENANCE.md`](MAINTENANCE.md).

## Image Versioning Policy

- `docker-compose.yml` is the runtime source of truth for infrastructure services (`postgres`, `redis`, `minio`, `prometheus`, `grafana`).
- External images should be pinned with immutable references (`tag@sha256:digest` or `@sha256:digest`) to avoid drift.
- `environments/*.manifest.env` controls only app promotions (`BACKEND_IMAGE`, `FRONTEND_IMAGE`) and should use immutable `sha-*` tags.
- Update flow: bump in staging first, validate smoke checks, then promote to production via PR.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch naming, workflow, deploy process, and PR guidelines.
