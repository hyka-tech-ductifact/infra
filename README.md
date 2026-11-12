# Ductifact — Infrastructure

Infrastructure configuration for the **production** and **staging** environments of Ductifact.

This repo is cloned on the server (`~/ductifact/infra/`) and contains everything needed to orchestrate services with Docker Compose.

**This repo is the source of truth for production deployments** — merging changes to `environments/production.manifest.env` triggers a deploy.

## Project Structure

```
├── .github/workflows/
│   ├── ci.yml                   # CI: validates compose + observability + scripts
│   ├── propose-staging.yml      # Opens auto-merge PR for staging manifest updates
│   ├── deploy-staging.yml       # Deploys staging when staging manifest changes on main
│   ├── propose-production.yml   # Opens production promotion PR (manual approval)
│   ├── deploy-production.yml    # Deploys production when production manifest changes on main
│   └── _deploy.yml              # Shared deploy workflow (SSH + env sync + deploy script)
├── docker-compose.yml           # Production/staging compose (single source of truth)
├── environments/
│   ├── production.manifest.env  # 🎯 Production manifest (image versions)
│   ├── production.config.env    # Production runtime config + explicit secret placeholders
│   ├── staging.manifest.env     # Staging manifest (image versions)
│   ├── staging.config.env       # Staging runtime config + explicit secret placeholders
│   └── images.manifest.env      # Shared infra/base images (postgres, redis, RustFS (S3), ...)
├── .env.contract                # Required variables + secret markers; also a template
├── observability/               # Prometheus + Grafana configuration
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── alerts.yml
│   └── grafana/
│       ├── provisioning/
│       └── dashboards/
└── scripts/
    ├── deploy.sh                # Deploy script (reads only .env.<env>)
    ├── smoke.sh                 # Post-deploy health checks
    ├── validate_env.sh          # Runtime env validation against .env.contract
    └── validate_repo.sh         # Repo validation using .env.contract key sets
```

## Deployment Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ STAGING (automatic via PR + auto-merge)                           │
│                                                                   │
│ backend/frontend image publish                                     │
│   → propose-staging.yml opens PR updating staging.manifest.env    │
│   → CI ✅ + auto-merge                                             │
│   → deploy-staging.yml                                             │
│   → _deploy.yml builds .env.staging from environments/* + secrets │
│   → SSH to server → deploy.sh staging                             │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ PRODUCTION (semi-automatic via GitOps)                            │
│                                                                   │
│ 1. Human validates in staging                                     │
│ 2. Trigger propose-production.yml (manual)                        │
│ 3. Workflow opens PR bumping RELEASE_VERSION + production images   │
│ 4. Human reviews + approves + merges                              │
│ 5. deploy-production.yml triggers                                 │
│ 6. _deploy.yml builds .env.production from environments/* + secrets│
│ 7. SSH to server → deploy.sh production                           │
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
- `propose-production.yml` bumps patch version in `environments/production.manifest.env`.
- Merging that PR triggers `deploy-production.yml` and release creation.
- Release notes include deployed backend/frontend image refs from `environments/production.manifest.env`.
- `environments/production.manifest.env` also includes `RELEASE_VERSION` (manually maintained) and is injected into backend runtime for `/readyz`.

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

# 2. Optional local bootstrap: copy the contract and replace example values
cp .env.contract .env.local
# Set local images in .env.local (required for local deploy)
# BACKEND_IMAGE=backend-app
# FRONTEND_IMAGE=frontend-app
# CI-driven deploys build .env.staging/.env.production from environments/* + GitHub Environment secrets
# deploy.sh never generates .env files; it only consumes .env.local/.env.staging/.env.production

# 3. Log in to ghcr.io
echo "YOUR_GITHUB_TOKEN" | docker login ghcr.io -u YOUR_USER --password-stdin

# 4. Start the environments
./scripts/deploy.sh staging
./scripts/deploy.sh production
```

## Required Secrets (GitHub)

| Secret | Used by | Purpose |
|--------|---------|---------|
| `VPS_SSH_KEY` | deploy-staging/deploy-production | SSH key for server access |
| `VPS_USER` | deploy-staging/deploy-production | Server username |
| `VPS_HOST` | deploy-staging/deploy-production | Server hostname (Cloudflare Tunnel) |
| `CF_ACCESS_CLIENT_ID` | deploy-staging/deploy-production | Cloudflare Access service token ID |
| `CF_ACCESS_CLIENT_SECRET` | deploy-staging/deploy-production | Cloudflare Access service token secret |
| `DB_PASSWORD` | deploy-staging/deploy-production | Database password |
| `JWT_SECRET` | deploy-staging/deploy-production | JWT signing secret |
| `S3_ACCESS_KEY` | deploy-staging/deploy-production | S3 access key |
| `S3_SECRET_KEY` | deploy-staging/deploy-production | S3 secret key |
| `SMTP_USERNAME` | deploy-staging/deploy-production | SMTP username |
| `SMTP_PASSWORD` | deploy-staging/deploy-production | SMTP password / API key |
| `REDIS_PASSWORD` | deploy-staging/deploy-production | Redis password |
| `INFRA_PAT` | backend/frontend repos | PAT with `repo` scope to dispatch events to this repo |

## S3 storage rollout

The `s3` service runs the same pinned RustFS image as backend development.
Compose passes `S3_HOST=s3`, `S3_PORT=9000`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`,
`S3_BUCKET`, and `S3_USE_SSL=false` to the backend. HTTP is used on the internal
Docker network; only the console is published on localhost via `S3_CONSOLE_PORT`.
The server receives the credentials through its required `RUSTFS_*` variables.

Before deploying this change to an existing environment:

1. Create `S3_ACCESS_KEY` and `S3_SECRET_KEY` in both GitHub Environments
   (`staging` and `production`), and update any manually maintained `.env.*` files
   to the keys in `.env.contract`, including `S3_IMAGE`.
2. Back up the existing object store. Start RustFS separately with a fresh volume
   and configure two S3 remotes in `rclone`: `source` for the previous server and
   `destination` for RustFS. Keep the current bucket name for each environment.
3. Pause uploads and deletes, copy objects with
   `rclone copy source:BUCKET destination:BUCKET`, then verify them with
   `rclone check source:BUCKET destination:BUCKET --download`.
4. Point the `s3` service at the populated RustFS volume before deploying, then
   run `./scripts/smoke.sh staging` (or `production`) and verify existing images
   through the API before resuming writes.

The new volume is `ductifact-<environment>_rustfs_data` by default. The previous
server's volume is retained; its data format must not be mounted directly into
RustFS. A normal deploy does not copy objects into the new volume.

Storage health is checked by Compose and `smoke.sh` via `/health`, and the backend
checks S3 connectivity through `/readyz`. RustFS metrics require an
[OpenTelemetry Collector](https://docs.rustfs.com/en/operations/observability);
storage metrics collection is not configured in this stack yet.

## Notes

- `.env.production`, `.env.staging`, and `.env.local` are **runtime files only** and are **never committed**.
- `.env.contract` defines the required runtime variables and identifies secrets with `SECRET_IN_GITHUB_ENV`. It also serves as a template; its example values are not runtime defaults.
- `validate_env.sh` checks that variables from `.env.contract` are present and non-empty in `.env.<env>`.
- `validate_repo.sh` derives config, platform image, and secret key sets from `.env.contract` to validate `environments/*`.
- `deploy.sh` validates `.env.<env>` against the contract before deploying, then consumes that file as its only runtime source of truth.
- `environments/*.config.env` and `environments/*manifest.env` are **auxiliary build inputs** used to construct final `.env` files.
- Sensitive values are never committed; placeholders in config (`SECRET_IN_GITHUB_ENV`) are replaced in CI.
- Staging and production use **different credentials** (DB, JWT).
- Ports are only exposed on `127.0.0.1` — Caddy (host-level) handles reverse proxying.
- Full CD guide available at `backend/docs/GUIDE_CD.md`.
- Server maintenance (logs, backups, rollbacks, security) documented in [`MAINTENANCE.md`](MAINTENANCE.md).

## Image Versioning Policy

- `docker-compose.yml` is the runtime source of truth for infrastructure services (`postgres`, `redis`, `s3`, `prometheus`, `grafana`).
- External images should be pinned with immutable references (`tag@sha256:digest` or `@sha256:digest`) to avoid drift.
- `environments/{staging,production}.manifest.env` controls app promotions (`BACKEND_IMAGE`, `FRONTEND_IMAGE`) and should use immutable `sha-*` tags.
- Local uses `.env.local` for `BACKEND_IMAGE` and `FRONTEND_IMAGE`.
- Update flow: bump in staging first, validate smoke checks, then promote to production via PR.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch naming, workflow, deploy process, and PR guidelines.
