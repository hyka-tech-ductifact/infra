#!/usr/bin/env bash
# deploy.sh — Deploy a ductifact environment.
# Usage: ./scripts/deploy.sh <environment> <image>
#   environment: staging | prod
#   image:       full image URI (e.g. ghcr.io/user/ductifact:staging)
#
# Example:
#   ./scripts/deploy.sh staging ghcr.io/hyka-tech-ductifact/ductifact:staging
#   ./scripts/deploy.sh prod    ghcr.io/hyka-tech-ductifact/ductifact:latest

set -euo pipefail

# ── Validate arguments ───────────────────────────────────────
ENV="${1:-}"
IMAGE="${2:-}"

if [[ -z "$ENV" || -z "$IMAGE" ]]; then
  echo "Usage: $0 <environment> <image>"
  echo "  environment: staging | prod"
  echo "  image:       full image URI"
  exit 1
fi

case "$ENV" in
  staging)
    COMPOSE_FILE="docker-compose.staging.yml"
    ENV_FILE=".env.staging"
    CONTAINER="ductifact_staging_app"
    ;;
  prod)
    COMPOSE_FILE="docker-compose.prod.yml"
    ENV_FILE=".env.prod"
    CONTAINER="ductifact_prod_app"
    ;;
  *)
    echo "ERROR: unknown environment '$ENV'. Use 'staging' or 'prod'."
    exit 1
    ;;
esac

# ── Navigate to infra directory ──────────────────────────────
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA_DIR"

echo "=== Deploying $ENV ==="
echo "Image:     $IMAGE"
echo "Compose:   $COMPOSE_FILE"
echo "Directory: $INFRA_DIR"

# ── Pull latest infra config ────────────────────────────────
echo "Pulling latest infra config..."
git pull --ff-only origin main

# ── Pull Docker image ────────────────────────────────────────
echo "Pulling image..."
docker pull "$IMAGE"

# ── Restart containers ───────────────────────────────────────
echo "Restarting containers..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d app

# ── Verify container is running ──────────────────────────────
echo "Waiting for container to start..."
sleep 5

if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "ERROR: $CONTAINER is not running"
  docker logs --tail=30 "$CONTAINER"
  exit 1
fi

# ── Cleanup ──────────────────────────────────────────────────
docker image prune -f

echo "=== $ENV deploy successful! ==="
