#!/usr/bin/env bash
# validate.sh — Validate all infra configs and scripts.
#
# Runs the same checks that CI executes, so issues are caught locally
# before pushing.
#
#   1. docker-compose.yml syntax
#   2. Prometheus config
#   3. Prometheus alert rules
#   4. Grafana dashboard JSON
#   5. Grafana provisioning YAML
#   6. ShellCheck on all scripts
#
# Usage:
#   ./scripts/validate.sh
#
# Examples:
#   cd infra && ./scripts/validate.sh
#   ./scripts/validate.sh               # from infra/scripts/

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

# ── Resolve infra root ──────────────────────────────────────
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA_DIR"

echo ""
echo "=== Validate infra configs ==="
echo ""

# ── Dummy env vars for docker compose config ────────────────
# Only needed so variable interpolation works; no containers are started.
export ENV="${ENV:-validate}"
export APP_IMAGE="${APP_IMAGE:-placeholder}"
export APP_PORT="${APP_PORT:-8080}"
export DB_USER="${DB_USER:-x}"
export DB_PASSWORD="${DB_PASSWORD:-x}"
export DB_NAME="${DB_NAME:-x}"
export JWT_SECRET="${JWT_SECRET:-validate-placeholder-secret-32chars}"
export CORS_ORIGINS="${CORS_ORIGINS:-*}"
export LOG_LEVEL="${LOG_LEVEL:-error}"
export LOG_FORMAT="${LOG_FORMAT:-text}"
export GIN_MODE="${GIN_MODE:-release}"
export AUTO_MIGRATE="${AUTO_MIGRATE:-false}"
export PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
export PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-1d}"
export GRAFANA_PORT="${GRAFANA_PORT:-3000}"
export GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-x}"

# ── 1. docker-compose.yml ───────────────────────────────────
echo "Docker Compose:"

if docker compose config --quiet 2>/dev/null; then
  pass "docker-compose.yml is valid"
else
  fail "docker-compose.yml has errors"
fi

# ── 2. Prometheus config ────────────────────────────────────
echo ""
echo "Prometheus:"

PROM_IMAGE="prom/prometheus:v3.3.0"

if docker run --rm --entrypoint promtool \
  -v "${INFRA_DIR}/observability/prometheus:/etc/prometheus" \
  "$PROM_IMAGE" \
  check config /etc/prometheus/prometheus.yml > /dev/null 2>&1; then
  pass "prometheus.yml is valid"
else
  fail "prometheus.yml has errors"
fi

# ── 3. Prometheus alert rules ───────────────────────────────
if docker run --rm --entrypoint promtool \
  -v "${INFRA_DIR}/observability/prometheus:/etc/prometheus" \
  "$PROM_IMAGE" \
  check rules /etc/prometheus/alerts.yml > /dev/null 2>&1; then
  pass "alerts.yml rules are valid"
else
  fail "alerts.yml has errors"
fi

# ── 4. Grafana dashboards (JSON) ────────────────────────────
echo ""
echo "Grafana:"

for f in observability/grafana/dashboards/*.json; do
  if python3 -m json.tool "$f" > /dev/null 2>&1; then
    pass "$(basename "$f") is valid JSON"
  else
    fail "$(basename "$f") is invalid JSON"
  fi
done

# ── 5. Grafana provisioning (YAML) ──────────────────────────
while IFS= read -r -d '' f; do
  if python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    pass "$(basename "$f") is valid YAML"
  else
    fail "$(basename "$f") is invalid YAML"
  fi
done < <(find observability/grafana/provisioning \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)

# ── 6. ShellCheck ────────────────────────────────────────────
echo ""
echo "ShellCheck:"

if command -v shellcheck > /dev/null 2>&1; then
  for f in scripts/*.sh; do
    if shellcheck "$f" > /dev/null 2>&1; then
      pass "$(basename "$f") passes shellcheck"
    else
      fail "$(basename "$f") has shellcheck warnings"
    fi
  done
else
  info "shellcheck not installed — skipping (apt install shellcheck)"
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "${GREEN}All checks passed.${NC}"
else
  echo -e "${RED}${FAILURES} check(s) failed.${NC}"
  exit 1
fi
