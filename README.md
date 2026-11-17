# Ductifact — Infrastructure

Docker Compose configuration for local, staging, and production. The server
checkout lives at `~/ductifact/infra`.

Published service ports bind to `127.0.0.1`; Caddy and Cloudflare Tunnel provide
external access. Prometheus/Grafana configuration lives in `observability/`.

## Deployment flow

### Staging — automatic

```text
Backend/frontend publishes an image
  ↓
propose-staging.yml opens a PR updating staging.manifest.env
  ↓
CI passes → PR auto-merges into main
  ↓
deploy-staging.yml
  ↓
Generate .env.staging from environments/* + GitHub staging secrets
  ↓
Upload to server → update checkout → deploy.sh staging
  ↓
Validate configuration → pull images → start services → health checks
```

Staging also deploys when its config, shared platform images, or Compose file
changes on `main`.

### Production — reviewed promotion

```text
Validate the application in staging
  ↓
Run propose-production.yml manually (patch/minor/major)
  ↓
PR copies staging images to production.manifest.env + bumps RELEASE_VERSION
  ↓
Review and merge into main
  ↓
deploy-production.yml
  ↓
Generate .env.production from environments/* + GitHub production secrets
  ↓
Upload to server → update checkout → deploy.sh production
  ↓
Validate configuration → pull images → start services → health checks
  ↓
Create the version tag and GitHub Release
```

Production deploys when `environments/production.manifest.env` changes on `main`.
Use immutable `sha-*` app images and pinned digests for shared platform images.
`RELEASE_VERSION` identifies the deployed release in the backend's `/readyz` response.

## Configuration

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Services, networks, volumes, and healthchecks |
| `environments/<env>.config.env` | Versioned settings; CI secret placeholders for staging/production |
| `environments/<env>.manifest.env` | Application image versions; production also defines `RELEASE_VERSION` |
| `environments/images.manifest.env` | Shared platform image versions |
| `.env.contract` | Required variables and secret markers used by validation |
| `.env.local`, `.env.staging`, `.env.production` | Final runtime files consumed by deployment; never committed |

The generator combines the environment config, app manifest, and shared images.
CI injects current GitHub Environment secrets and replaces the server's runtime
file on each deployment. Persistent remote changes belong in the versioned
inputs or GitHub secrets. Changing a secret alone does not trigger a deployment.

Keep runtime files on the server: maintenance commands also need them. Generated
files have permissions `600`.

## Local setup

Requires Bash 4.4+, Docker Compose v2 with `config --environment` and
`up --wait --wait-timeout`, and `jq`.

From `infra/`, with `backend/` and `frontend/` checked out beside it:

```bash
docker build -t backend-app ../backend
docker build -t frontend-app ../frontend
./scripts/ops/generate_env.sh local
./scripts/ops/deploy.sh local
```

Local config contains development-only credentials. Edit `.env.local` for personal
settings. Generation refuses to overwrite an existing file; `--force` replaces
it completely, including credentials. Keep credentials consistent with existing
service volumes.

SMTP runs outside this stack. Set a reachable endpoint in `.env.local`; the default
`host.docker.internal:1025` needs a host mapping on Linux.

## Server and GitHub setup

Clone this repo at `~/ductifact/infra` on the server. Install the deployment
requirements above and configure access to the application image registry.
Create separate GitHub Environments named `staging` and `production` with:

| Purpose | Secrets |
|---------|---------|
| SSH | `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY` |
| Cloudflare Access | `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` |
| Application | `DB_PASSWORD`, `JWT_SECRET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `REDIS_PASSWORD` |
| Email | `SMTP_USERNAME`, `SMTP_PASSWORD` |

The promotion workflows also use `INFRA_PAT`; image-publishing repos use it to
notify this repo. Deployment workflows call `scripts/ci/deploy_remote.sh` to
generate configuration, upload it, and deploy over SSH.

## Guides

- [Scripts](scripts/README.md): commands, execution locations, and automatic calls.
- [Maintenance](MAINTENANCE.md): logs, backups, rollback, and storage migration.
- [Contributing](CONTRIBUTING.md): PR workflow and validation.
