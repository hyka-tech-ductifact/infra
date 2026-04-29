#!/usr/bin/env bash
# smoke.sh — Post-deploy smoke tests for a ductifact environment.
#
# Verifies that all services are healthy and communicating:
#   1. App API responds on /healthz (liveness) and /readyz (readiness)
#   2. PostgreSQL is reachable (via /readyz)
#   3. MinIO is healthy
#   4. Redis is healthy
#   5. Prometheus is healthy
#   6. Prometheus is scraping the app successfully
#   7. Grafana is healthy
#
# Usage:
#   ./scripts/smoke.sh <environment>
#
#   environment: local | staging | prod
#
# Examples:
#   ./scripts/smoke.sh local
#   ./scripts/smoke.sh staging

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

pass() { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${YELLOW}…${NC} $1"; }

FAILURES=0

# ── Validate arguments ──────────────────────────────────────
ENV="${1:-}"

if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <environment>"
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

# ── Load env file ───────────────────────────────────────────
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${INFRA_DIR}/.env.${ENV}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found."
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

BASE_URL="http://localhost:${APP_PORT}"
PROM_CONTAINER="ductifact_${ENV}_prometheus"
GRAF_URL="http://localhost:${GRAFANA_PORT}"

echo ""
echo "=== Smoke tests for '$ENV' ==="
echo ""

# ── 1. App health endpoint ──────────────────────────────────
echo "App (${BASE_URL}):"

if curl -sf --max-time 5 "${BASE_URL}/healthz" > /dev/null 2>&1; then
  pass "/healthz (liveness) responds OK"
else
  fail "/healthz (liveness) is not reachable"
fi

if curl -sf --max-time 5 "${BASE_URL}/readyz" > /dev/null 2>&1; then
  READYZ_BODY=$(curl -s --max-time 5 "${BASE_URL}/readyz")
  READYZ_STATUS=$(echo "$READYZ_BODY" | grep -o '"status":"[^"]*"' | head -1)
  if echo "$READYZ_STATUS" | grep -q '"status":"ready"'; then
    pass "/readyz (readiness) responds OK — ready"
  elif echo "$READYZ_STATUS" | grep -q '"status":"degraded"'; then
    echo -e "  ${YELLOW}⚠${NC} /readyz (readiness) responds OK — degraded"
    DEGRADED_SERVICES=$(echo "$READYZ_BODY" | grep -o '"warnings":\[[^]]*\]' | sed 's/"warnings":\[//;s/\]//;s/"//g' | tr ',' '\n')
    while IFS= read -r svc; do
      [[ -n "$svc" ]] && echo -e "    ${YELLOW}↳${NC} $svc"
    done <<< "$DEGRADED_SERVICES"
  fi
else
  fail "/readyz (readiness) is not reachable (503 or timeout)"
fi

# ── 2. App metrics endpoint (Prometheus exposition) ─────────
if curl -sf --max-time 5 "${BASE_URL}/metrics" > /dev/null 2>&1; then
  pass "/metrics endpoint available"
else
  fail "/metrics endpoint is not reachable"
fi

# ── 3. MinIO health ─────────────────────────────────────────
echo ""
MINIO_CONTAINER="ductifact_${ENV}_minio"
echo "MinIO (${MINIO_CONTAINER}):"

if docker inspect --format='{{.State.Running}}' "$MINIO_CONTAINER" 2>/dev/null | grep -q true; then
  pass "MinIO container is running"
else
  fail "MinIO container is not running"
fi

if docker exec "$MINIO_CONTAINER" curl -sf --max-time 5 http://localhost:9000/minio/health/live > /dev/null 2>&1; then
  pass "MinIO health endpoint responds OK"
else
  fail "MinIO health endpoint is not reachable"
fi

# ── 4. Redis health ─────────────────────────────────────────
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

# ── 5. Prometheus health ────────────────────────────────────
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

# ── 6. Prometheus scraping the app ──────────────────────────
# Prometheus may need a few seconds to complete the first scrape after startup.
SCRAPE_OK=false
for _ in 1 2 3 4 5; do
  TARGETS_JSON=$(docker exec "$PROM_CONTAINER" wget -qO- --timeout=5 http://localhost:9090/api/v1/targets 2>/dev/null || echo "")
  if [[ -n "$TARGETS_JSON" ]] && \
     echo "$TARGETS_JSON" | grep -q '"job":"ductifact-api"' && \
     echo "$TARGETS_JSON" | grep -q '"health":"up"'; then
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

# ── 7. Grafana health ──────────────────────────────────────
echo ""
echo "Grafana (${GRAF_URL}):"

if curl -sf --max-time 5 "${GRAF_URL}/api/health" > /dev/null 2>&1; then
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
