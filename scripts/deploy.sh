#!/usr/bin/env bash
# deploy.sh — Deploy or stop a ductifact environment.
#
# Usage:
#   ./scripts/deploy.sh <environment>          # deploy + smoke tests
#   ./scripts/deploy.sh <environment> stop     # stop all containers
#
#   environment: local | staging | prod
#
# The image and all config come from .env.<environment>.
# After a successful deploy, smoke tests run automatically to verify
# all services are healthy.
#
# Examples:
#   ./scripts/deploy.sh local            # start with local image + smoke
#   ./scripts/deploy.sh local stop       # stop local environment
#   ./scripts/deploy.sh staging          # pull + start staging + smoke
#   ./scripts/deploy.sh prod stop        # stop production

set -euo pipefail

# ── Validate arguments ───────────────────────────────────────
ENV="${1:-}"
ACTION="${2:-deploy}"

if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <environment> [stop]"
  echo "  environment: local | staging | prod"
  exit 1
fi

case "$ENV" in
  local|staging|prod) ;;
  *)
    echo "ERROR: unknown environment '$ENV'. Use 'local', 'staging', or 'prod'."
    exit 1
    ;;
esac

case "$ACTION" in
  deploy|stop) ;;
  *)
    echo "ERROR: unknown action '$ACTION'. Use 'stop' or omit for deploy."
    exit 1
    ;;
esac

ENV_FILE=".env.${ENV}"

# ── Navigate to infra directory ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy from ${ENV_FILE}.example and fill in values."
  exit 1
fi

# ── Stop ─────────────────────────────────────────────────────
if [[ "$ACTION" == "stop" ]]; then
  echo "=== Stopping $ENV ==="
  docker compose --env-file "$ENV_FILE" down
  echo "=== $ENV stopped ==="
  exit 0
fi

# ── Deploy ───────────────────────────────────────────────────
CONTAINER="ductifact_${ENV}_app"

# Read APP_IMAGE from env file
APP_IMAGE=$(grep -E '^APP_IMAGE=' "$ENV_FILE" | cut -d'=' -f2-)
if [[ -z "$APP_IMAGE" ]]; then
  echo "ERROR: APP_IMAGE not defined in $ENV_FILE"
  exit 1
fi

echo "=== Deploying $ENV ==="
echo "Image:     $APP_IMAGE"
echo "Env file:  $ENV_FILE"
echo "Directory: $INFRA_DIR"

# ── Pre-deploy validation ────────────────────────────────────
echo "Running pre-deploy validation..."
if ! "${SCRIPT_DIR}/validate.sh" "$ENV"; then
  echo "ERROR: Pre-deploy validation failed. Fix the issues above before deploying."
  exit 1
fi
echo ""

# ── Pull latest infra config (skip for local) ────────────────
if [[ "$ENV" != "local" ]]; then
  echo "Pulling latest infra config..."
  git pull --ff-only origin main
fi

# ── Pull Docker image (skip for local) ───────────────────────
if [[ "$ENV" != "local" ]]; then
  echo "Pulling image..."
  docker pull "$APP_IMAGE"
fi

# ── Restart containers ───────────────────────────────────────
echo "Restarting containers..."
docker compose --env-file "$ENV_FILE" up -d

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

# ── Post-deploy smoke tests ──────────────────────────────────
echo "Running post-deploy smoke tests..."
if "${SCRIPT_DIR}/smoke.sh" "$ENV"; then
  echo "=== $ENV deploy successful! ==="
else
  echo "ERROR: Deploy completed but smoke tests failed!"
  echo "Services may not be healthy. Check logs with:"
  echo "  docker logs ductifact_${ENV}_app --tail=50"
  exit 1
fi
