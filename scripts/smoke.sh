#!/usr/bin/env bash
# smoke.sh — Post-deploy smoke tests for a ductifact environment.
#
# Verifies that all services are healthy and communicating:
#   1. App API responds on /health
#   2. PostgreSQL is reachable (via app health)
#   3. Prometheus is healthy
#   4. Prometheus is scraping the app successfully
#   5. Grafana is healthy
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
PROM_URL="http://localhost:${PROMETHEUS_PORT}"
GRAF_URL="http://localhost:${GRAFANA_PORT}"

echo ""
echo "=== Smoke tests for '$ENV' ==="
echo ""

# ── 1. App health endpoint ──────────────────────────────────
echo "App (${BASE_URL}):"

if curl -sf --max-time 5 "${BASE_URL}/health" > /dev/null 2>&1; then
  pass "/health responds OK"
else
  fail "/health is not reachable"
fi

# ── 2. App metrics endpoint (Prometheus exposition) ─────────
if curl -sf --max-time 5 "${BASE_URL}/metrics" > /dev/null 2>&1; then
  pass "/metrics endpoint available"
else
  fail "/metrics endpoint is not reachable"
fi

# ── 3. Prometheus health ────────────────────────────────────
echo ""
echo "Prometheus (${PROM_URL}):"

if curl -sf --max-time 5 "${PROM_URL}/-/healthy" > /dev/null 2>&1; then
  pass "Prometheus is healthy"
else
  fail "Prometheus is not reachable"
fi

# ── 4. Prometheus scraping the app ──────────────────────────
TARGETS_JSON=$(curl -sf --max-time 5 "${PROM_URL}/api/v1/targets" 2>/dev/null || echo "")

if [[ -n "$TARGETS_JSON" ]]; then
  # Check that the ductifact-api job target is "up"
  if echo "$TARGETS_JSON" | grep -q '"job":"ductifact-api"' && \
     echo "$TARGETS_JSON" | grep -q '"health":"up"'; then
    pass "Scraping ductifact-api target (health=up)"
  else
    info "Prometheus reachable but ductifact-api target is not up yet"
    fail "ductifact-api target not healthy"
  fi
else
  fail "Could not query Prometheus targets API"
fi

# ── 5. Grafana health ──────────────────────────────────────
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
