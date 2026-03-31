# Ductifact — Infrastructure

Infrastructure configuration for the **production** and **staging** environments of Ductifact.

This repo is cloned on the server (`~/ductifact/infra/`) and contains everything needed to orchestrate services with Docker Compose.

## Structure

```
├── docker-compose.yml           # Unified compose for all environments
├── .env.prod.example            # Production environment variables template
├── .env.staging.example         # Staging environment variables template
├── observability/               # Prometheus + Grafana configuration
│   ├── prometheus/
│   │   ├── prometheus.prod.yml
│   │   ├── prometheus.staging.yml
│   │   └── alerts.yml
│   └── grafana/
│       ├── provisioning/
│       └── dashboards/
└── scripts/
    └── deploy.sh                # Deploy script (called from CD workflow)
```

## Setup

```bash
# 1. Clone on the server
git clone https://github.com/your-user/ductifact-infra.git ~/ductifact/infra
cd ~/ductifact/infra

# 2. Create .env files from the examples
cp .env.prod.example .env.prod
cp .env.staging.example .env.staging
# Edit both with real values (passwords, JWT, etc.)

# 3. Log in to ghcr.io
echo "YOUR_GITHUB_TOKEN" | docker login ghcr.io -u YOUR_USER --password-stdin

# 4. Start the environments
docker compose --env-file .env.staging up -d
docker compose --env-file .env.prod up -d
```

## Deploy

Deploys are triggered automatically by GitHub Actions (CD) via SSH:

```bash
# Staging — automatic after merge to main
# Production — automatic after pushing a v* tag

# Can also be run manually:
./scripts/deploy.sh staging ghcr.io/your-user/ductifact:staging
./scripts/deploy.sh prod    ghcr.io/your-user/ductifact:latest
```

## Notes

- `.env.prod` and `.env.staging` are **never committed** (listed in `.gitignore`).
- Staging and production use **different credentials** (DB, JWT).
- Ports are only exposed on `127.0.0.1` — Caddy (host-level) handles reverse proxying.
- Full CD guide available at `backend/docs/GUIDE_CD.md`.
- Server maintenance (logs, backups, rollbacks, security) documented in [`MAINTENANCE.md`](MAINTENANCE.md).
