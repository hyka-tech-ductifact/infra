#!/usr/bin/env bash
# Check service health and communication after deployment.
# Runs on: Machine running the target containers; requires curl and jq.
# Called by: ops/deploy.sh or operator for diagnosis.
# Calls: No other repository scripts.
# Usage: ./scripts/checks/health.sh <local|staging|production>

set -euo pipefail

command -v jq >/dev/null || { echo "ERROR: jq is required for JSON health checks" >&2; exit 1; }

# ── Helpers ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

pass() { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${YELLOW}…${NC} $1"; }

wait_http_ok() {
  local url="$1"
  local attempts="${2:-10}"
  local sleep_seconds="${3:-3}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if HTTP_BODY=$(curl -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null); then
      return 0
    fi
    if ((i < attempts)); then sleep "$sleep_seconds"; fi
  done

  return 1
}

FAILURES=0

# ── Validate arguments ──────────────────────────────────────
ENV="${1:-}"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <environment>"
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

# ── Load env file ───────────────────────────────────────────
INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${INFRA_DIR}/.env.${ENV}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found."
  exit 1
fi

# Let Compose read the same values used by the containers.
ENV_VALUES="$(docker compose --project-directory "$INFRA_DIR" --env-file "$ENV_FILE" config --environment)"
while IFS='=' read -r key value; do
  case "$key" in
    BACKEND_PORT|FRONTEND_PORT|GRAFANA_PORT|REDIS_PASSWORD) export "$key=$value" ;;
  esac
done <<< "$ENV_VALUES"
unset ENV_VALUES

BACKEND_URL="http://localhost:${BACKEND_PORT}"
FRONTEND_URL="http://localhost:${FRONTEND_PORT}"
PROM_CONTAINER="ductifact_${ENV}_prometheus"
GRAF_URL="http://localhost:${GRAFANA_PORT}"

echo ""
echo "=== Smoke tests for '$ENV' ==="
echo ""

# ── 1. Backend health endpoint ──────────────────────────────
echo "Backend (${BACKEND_URL}):"

if wait_http_ok "${BACKEND_URL}/healthz" 10 3; then
  pass "/healthz (liveness) responds OK"
else
  fail "/healthz (liveness) is not reachable"
fi

if wait_http_ok "${BACKEND_URL}/readyz" 10 3; then
  # Parse the same response that succeeded; do not issue a second request.
  READYZ_STATUS=$(jq -er '.status | select(type == "string")' <<< "$HTTP_BODY" 2>/dev/null || true)
  case "$READYZ_STATUS" in
    ready) pass "/readyz (readiness) responds OK — ready" ;;
    degraded)
      info "/readyz responds OK — degraded"
      jq -r '.warnings[]? | "    " + .' <<< "$HTTP_BODY"
      ;;
    *) fail "/readyz returned an invalid or unexpected status" ;;
  esac
else
  fail "/readyz (readiness) is not reachable (503 or timeout)"
fi

# ── 2. Backend metrics endpoint (Prometheus exposition) ─────────
if wait_http_ok "${BACKEND_URL}/metrics" 10 3; then
  pass "/metrics endpoint available"
else
  fail "/metrics endpoint is not reachable"
fi

# ── 3. Frontend health ──────────────────────────────────────
echo ""
echo "Frontend (${FRONTEND_URL}):"

if wait_http_ok "${FRONTEND_URL}" 15 3; then
  pass "Frontend responds OK (Nginx is serving)"
else
  fail "Frontend is not reachable"
fi

# ── 4. S3 storage health ─────────────────────────────────────────
echo ""
S3_CONTAINER="ductifact_${ENV}_s3"
echo "S3 storage (${S3_CONTAINER}):"

if docker inspect --format='{{.State.Running}}' "$S3_CONTAINER" 2>/dev/null | grep -q true; then
  pass "S3 storage container is running"
else
  fail "S3 storage container is not running"
fi

if docker exec "$S3_CONTAINER" curl -sf --max-time 5 http://127.0.0.1:9000/health > /dev/null 2>&1; then
  pass "S3 storage health endpoint responds OK"
else
  fail "S3 storage health endpoint is not reachable"
fi

# ── 5. Redis health ─────────────────────────────────────────
echo ""
REDIS_CONTAINER="ductifact_${ENV}_redis"
echo "Redis (${REDIS_CONTAINER}):"

if docker inspect --format='{{.State.Running}}' "$REDIS_CONTAINER" 2>/dev/null | grep -q true; then
  pass "Redis container is running"
else
  fail "Redis container is not running"
fi

if docker exec "$REDIS_CONTAINER" redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
  pass "Redis responds to PING"
else
  fail "Redis is not responding to PING"
fi

# ── 6. Prometheus health ────────────────────────────────────
echo ""
echo "Prometheus (${PROM_CONTAINER}):"

if docker inspect --format='{{.State.Running}}' "$PROM_CONTAINER" 2>/dev/null | grep -q true; then
  pass "Prometheus container is running"
else
  fail "Prometheus container is not running"
fi

if docker exec "$PROM_CONTAINER" wget -qO- --timeout=5 http://localhost:9090/-/healthy > /dev/null 2>&1; then
  pass "Prometheus is healthy"
else
  fail "Prometheus is not reachable"
fi

# ── 7. Prometheus scraping the backend ──────────────────────
# Prometheus may need a few seconds to complete the first scrape after startup.
SCRAPE_OK=false
for _ in 1 2 3 4 5; do
  TARGETS_JSON=$(docker exec "$PROM_CONTAINER" wget -qO- --timeout=5 http://localhost:9090/api/v1/targets 2>/dev/null || echo "")
  if jq -e '.status == "success" and
      ([.data.activeTargets[]? | select(.labels.job == "ductifact-api")] |
       length > 0 and all(.[]; .health == "up"))' <<< "$TARGETS_JSON" >/dev/null 2>&1; then
    SCRAPE_OK=true
    break
  fi
  sleep 3
done

if [[ "$SCRAPE_OK" == true ]]; then
  pass "Scraping ductifact-api target (health=up)"
else
  info "Prometheus reachable but ductifact-api target is not up yet (waited 15s)"
  fail "ductifact-api target not healthy"
fi

# ── 8. Grafana health ──────────────────────────────────────
echo ""
echo "Grafana (${GRAF_URL}):"

if wait_http_ok "${GRAF_URL}/api/health" 15 3; then
  pass "Grafana is healthy"
else
  fail "Grafana is not reachable"
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}=== All smoke tests passed ===${NC}"
  echo ""
  exit 0
else
  echo -e "${RED}=== ${FAILURES} smoke test(s) failed ===${NC}"
  echo ""
  exit 1
fi
