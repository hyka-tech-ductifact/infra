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
CONTAINER_BACKEND="ductifact_${ENV}_backend"
CONTAINER_FRONTEND="ductifact_${ENV}_frontend"

# ── Pull latest infra config (skip for local) ────────────────
if [[ "$ENV" != "local" ]]; then
  echo "Pulling latest infra config..."
  git pull --ff-only origin main
fi

# ── Read images from manifest (environments/<env>.manifest.env) ───────
# The manifest is the source of truth for which image versions to deploy.
# Falls back to .env.<env> if no manifest exists (backward compat).
case "$ENV" in
  local)
    MANIFEST_FILE="${INFRA_DIR}/environments/local.manifest.env"
    ;;
  staging)
    MANIFEST_FILE="${INFRA_DIR}/environments/staging.manifest.env"
    ;;
  prod)
    MANIFEST_FILE="${INFRA_DIR}/environments/production.manifest.env"
    ;;
esac

if [[ -f "$MANIFEST_FILE" ]]; then
  echo "Reading image versions from manifest: $MANIFEST_FILE"
  BACKEND_IMAGE=$(grep -E '^BACKEND_IMAGE=' "$MANIFEST_FILE" | cut -d'=' -f2-)
  FRONTEND_IMAGE=$(grep -E '^FRONTEND_IMAGE=' "$MANIFEST_FILE" | cut -d'=' -f2-)
  RELEASE_VERSION=$(grep -E '^RELEASE_VERSION=' "$MANIFEST_FILE" | cut -d'=' -f2- || true)
else
  echo "No manifest found at $MANIFEST_FILE, reading from $ENV_FILE"
  BACKEND_IMAGE=$(grep -E '^BACKEND_IMAGE=' "$ENV_FILE" | cut -d'=' -f2-)
  FRONTEND_IMAGE=$(grep -E '^FRONTEND_IMAGE=' "$ENV_FILE" | cut -d'=' -f2-)
  RELEASE_VERSION=$(grep -E '^RELEASE_VERSION=' "$ENV_FILE" | cut -d'=' -f2- || true)
fi

if [[ -z "$BACKEND_IMAGE" ]]; then
  echo "ERROR: BACKEND_IMAGE not defined"
  exit 1
fi
if [[ -z "$FRONTEND_IMAGE" ]]; then
  echo "ERROR: FRONTEND_IMAGE not defined"
  exit 1
fi

# Export so docker compose can use them (overrides .env.<env> values)
export BACKEND_IMAGE
export FRONTEND_IMAGE
export RELEASE_VERSION="${RELEASE_VERSION:-unknown}"

echo "=== Deploying $ENV ==="
echo "Backend:   $BACKEND_IMAGE"
echo "Frontend:  $FRONTEND_IMAGE"
echo "Release:   $RELEASE_VERSION"
echo "Manifest:  ${MANIFEST_FILE:-none}"
echo "Env file:  $ENV_FILE"
echo "Directory: $INFRA_DIR"

# ── Pre-deploy validation ────────────────────────────────────
echo "Running pre-deploy validation..."
if ! "${SCRIPT_DIR}/validate.sh" "$ENV"; then
  echo "ERROR: Pre-deploy validation failed. Fix the issues above before deploying."
  exit 1
fi
echo ""

# ── Pull Docker images (skip for local) ──────────────────────
if [[ "$ENV" != "local" ]]; then
  echo "Pulling images..."
  docker pull "$BACKEND_IMAGE" || echo "⚠ Backend image not found — skipping pull"
  docker pull "$FRONTEND_IMAGE" || echo "⚠ Frontend image not found — skipping pull"
fi

# ── Restart containers ───────────────────────────────────────
echo "Restarting containers..."
docker compose --env-file "$ENV_FILE" up -d --remove-orphans

# ── Verify containers are running ────────────────────────────
echo "Waiting for containers to start..."
sleep 5

for CONTAINER in "$CONTAINER_BACKEND" "$CONTAINER_FRONTEND"; do
  if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: $CONTAINER is not running"
    docker logs --tail=30 "$CONTAINER"
    exit 1
  fi
  echo "✅ $CONTAINER is running"
done

# ── Cleanup ──────────────────────────────────────────────────
docker image prune -f

# ── Post-deploy smoke tests ──────────────────────────────────
echo "Running post-deploy smoke tests..."
if "${SCRIPT_DIR}/smoke.sh" "$ENV"; then
  echo "=== $ENV deploy successful! ==="
else
  echo "ERROR: Deploy completed but smoke tests failed!"
  echo "Services may not be healthy. Check logs with:"
  echo "  docker logs ductifact_${ENV}_backend --tail=50"
  exit 1
fi
