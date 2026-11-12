#!/usr/bin/env bash
# Deploy or stop services using an existing .env.<environment>.
# Runs on: Local machine or target server.
# Called by: Operator or ci/deploy_remote.sh over SSH.
# Calls: checks/env.sh before deployment; checks/health.sh afterwards.
# Usage: ./scripts/ops/deploy.sh <local|staging|production> [stop]

set -euo pipefail

# ── Validate arguments ───────────────────────────────────────
ENV="${1:-}"
ACTION="${2:-deploy}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <environment> [stop]"
  echo "  environment: local | staging | production"
  exit 1
fi

case "$ENV" in
  local|staging|production) ;;
  *)
    echo "ERROR: unknown environment '$ENV'. Use 'local', 'staging', or 'production'."
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
INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$INFRA_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Generate it with ./scripts/ops/generate_env.sh $ENV (CI provides secrets for staging/production)."
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
command -v jq >/dev/null || {
  echo "ERROR: jq is required by the post-deploy health checks. Install it before deploying." >&2
  exit 1
}
CONTAINER_BACKEND="ductifact_${ENV}_backend"
CONTAINER_FRONTEND="ductifact_${ENV}_frontend"

# ── Pre-deploy validation ────────────────────────────────────
echo "Running pre-deploy validation..."
if ! "${SCRIPT_DIR}/../checks/env.sh" "$ENV"; then
  echo "ERROR: Pre-deploy validation failed. Fix the generation inputs and regenerate $ENV_FILE."
  exit 1
fi
echo ""

# ── Check Compose configuration and pull images ──────────────────────
# CI updates the checkout before invoking this script. Manual deploys use the
# current checkout, so validation and deployment see the same configuration.
COMPOSE=(docker compose --env-file "$ENV_FILE")
"${COMPOSE[@]}" config --quiet

echo "=== Deploying $ENV using $ENV_FILE ==="
if [[ "$ENV" != local ]]; then
  # A failed pull must stop deployment instead of silently using an old image.
  "${COMPOSE[@]}" pull
fi

# ── Restart containers ───────────────────────────────────────
echo "Restarting containers..."
"${COMPOSE[@]}" up -d --remove-orphans

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

# ── Post-deploy smoke tests ──────────────────────────────────
echo "Running post-deploy smoke tests..."
if "${SCRIPT_DIR}/../checks/health.sh" "$ENV"; then
  echo "=== $ENV deploy successful! ==="
else
  echo "ERROR: Deploy completed but smoke tests failed!"
  echo "Services may not be healthy. Check logs with:"
  echo "  docker logs ductifact_${ENV}_backend --tail=50"
  exit 1
fi
