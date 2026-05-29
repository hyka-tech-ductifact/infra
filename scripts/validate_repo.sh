#!/usr/bin/env bash
# validate_repo.sh — Validate repo-level infra assets and auxiliary build inputs.
#
# Runs automatically in CI on every PR.
# Run locally before pushing changes to infra config files.
#
# Checks:
#   1. docker-compose.yml syntax
#   2. Prometheus config + alert rules
#   3. Grafana dashboards (JSON) + provisioning (YAML)
#   4. ShellCheck on all scripts
#   5. environments/images.manifest.env — all shared images present
#   6. environments/*.config.env — required keys + SECRET_IN_GITHUB_ENV placeholders
#   7. environments/production.manifest.env — RELEASE_VERSION present

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${YELLOW}…${NC} $1"; }

FAILURES=0
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA_DIR"

echo ""
echo "=== validate_repo ==="
echo ""

# ── 1. docker-compose.yml ────────────────────────────────────
echo "Docker Compose:"

while IFS= read -r var; do
  if [[ -z "${!var:-}" ]]; then
    export "$var=8080"
  fi
done < <(grep -oP '\$\{(\w+)' docker-compose.yml | sed 's/\${//' | sort -u)

if docker compose config --quiet 2>/dev/null; then
  pass "docker-compose.yml is valid"
else
  fail "docker-compose.yml has errors"
fi

# ── 2. Prometheus ─────────────────────────────────────────────
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

if docker run --rm --entrypoint promtool \
  -v "${INFRA_DIR}/observability/prometheus:/etc/prometheus" \
  "$PROM_IMAGE" \
  check rules /etc/prometheus/alerts.yml > /dev/null 2>&1; then
  pass "alerts.yml rules are valid"
else
  fail "alerts.yml has errors"
fi

# ── 3. Grafana ────────────────────────────────────────────────
echo ""
echo "Grafana:"

DASHBOARD_DIR="observability/grafana/dashboards"
if [[ -d "$DASHBOARD_DIR" ]]; then
  shopt -s nullglob
  json_files=("$DASHBOARD_DIR"/*.json)
  shopt -u nullglob
  if [[ ${#json_files[@]} -eq 0 ]]; then
    info "No dashboard JSON files found in $DASHBOARD_DIR"
  else
    for f in "${json_files[@]}"; do
      if python3 -m json.tool "$f" > /dev/null 2>&1; then
        pass "$(basename "$f") is valid JSON"
      else
        fail "$(basename "$f") is invalid JSON"
      fi
    done
  fi
else
  fail "Dashboard directory not found: $DASHBOARD_DIR"
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  info "pyyaml not installed — skipping YAML validation (pip install pyyaml)"
else
  while IFS= read -r -d '' f; do
    if python3 -c "
import yaml, sys
with open(sys.argv[1]) as fh:
    yaml.safe_load(fh)
" "$f" 2>/dev/null; then
      pass "$(basename "$f") is valid YAML"
    else
      fail "$(basename "$f") is invalid YAML"
    fi
  done < <(find observability/grafana/provisioning \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)
fi

# ── 4. ShellCheck ─────────────────────────────────────────────
echo ""
echo "ShellCheck:"

if ! command -v shellcheck > /dev/null 2>&1; then
  fail "shellcheck is not installed (apt install shellcheck)"
else
  for f in scripts/*.sh; do
    if shellcheck "$f" > /dev/null 2>&1; then
      pass "$(basename "$f") passes shellcheck"
    else
      fail "$(basename "$f") has shellcheck warnings"
    fi
  done
fi

# ── 5. Shared images manifest ─────────────────────────────────
echo ""
echo "Shared images manifest (environments/images.manifest.env):"

IMAGES_MANIFEST="environments/images.manifest.env"
if [[ ! -f "$IMAGES_MANIFEST" ]]; then
  fail "$IMAGES_MANIFEST not found"
else
  for key in POSTGRES_IMAGE MINIO_IMAGE REDIS_IMAGE PROMETHEUS_IMAGE GRAFANA_IMAGE; do
    if grep -qE "^${key}=.+" "$IMAGES_MANIFEST"; then
      pass "${key} is present"
    else
      fail "${key} is missing in $IMAGES_MANIFEST"
    fi
  done
fi

# ── 6. Runtime config manifests ───────────────────────────────
echo ""
echo "Runtime config manifests (environments/*.config.env):"

SECRET_KEYS=(DB_PASSWORD JWT_SECRET MINIO_ROOT_USER MINIO_ROOT_PASSWORD SMTP_USERNAME SMTP_PASSWORD REDIS_PASSWORD)
CONFIG_KEYS=(
  ENV FRONTEND_PORT DB_USER DB_NAME BACKEND_HOST BACKEND_PORT
  JWT_TOKEN_DURATION JWT_REFRESH_TOKEN_DURATION CORS_ORIGINS
  LOG_LEVEL LOG_FORMAT GIN_MODE
  RATE_LIMIT_IP_MAX RATE_LIMIT_IP_WINDOW RATE_LIMIT_USER_MAX RATE_LIMIT_USER_WINDOW
  LOGIN_THROTTLE_MAX_ATTEMPTS LOGIN_THROTTLE_WINDOW LOGIN_THROTTLE_LOCKOUT
  MINIO_BUCKET MINIO_CONSOLE_PORT
  SMTP_HOST SMTP_PORT SMTP_AUTH SMTP_FROM
  REDIS_HOST REDIS_PORT REDIS_AUTH REDIS_DB
  GRAFANA_PORT PROMETHEUS_RETENTION
  VERIFICATION_BASE_URL VERIFICATION_EMAIL_TOKEN_TTL VERIFICATION_PASSWORD_RESET_TOKEN_TTL
)

check_config_file() {
  local file="$1"
  local label="$2"

  if [[ ! -f "$file" ]]; then
    fail "$label: $file not found"
    return
  fi

  for key in "${CONFIG_KEYS[@]}"; do
    if grep -qE "^${key}=.+" "$file"; then
      pass "$label: $key is present"
    else
      fail "$label: $key is missing"
    fi
  done

  for key in "${SECRET_KEYS[@]}"; do
    if grep -qE "^${key}=SECRET_IN_GITHUB_ENV$" "$file"; then
      pass "$label: $key placeholder is explicit"
    elif grep -qE "^${key}=" "$file"; then
      fail "$label: $key must be SECRET_IN_GITHUB_ENV (not a real value)"
    else
      fail "$label: $key placeholder is missing"
    fi
  done
}

check_config_file "environments/staging.config.env"    "staging.config.env"
check_config_file "environments/production.config.env" "production.config.env"

# ── 7. Production manifest preflight ─────────────────────────
# Full semver + tag-collision validation is done in deploy-production.yml.
echo ""
echo "Production manifest (environments/production.manifest.env):"

PROD_MANIFEST="environments/production.manifest.env"
if [[ ! -f "$PROD_MANIFEST" ]]; then
  fail "$PROD_MANIFEST not found"
else
  release_version_line=$(grep -E '^RELEASE_VERSION=' "$PROD_MANIFEST" || true)
  if [[ -z "$release_version_line" ]]; then
    fail "RELEASE_VERSION is missing"
  else
    pass "RELEASE_VERSION is present (${release_version_line#*=})"
  fi
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "${GREEN}All repo checks passed.${NC}"
else
  echo -e "${RED}${FAILURES} check(s) failed.${NC}"
  exit 1
fi
