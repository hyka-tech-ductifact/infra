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
#   7. Production release version format in manifest
#   8. Environment variables completeness (when <environment> is given)
#
# Usage:
#   ./scripts/validate.sh                    # validate configs only
#   ./scripts/validate.sh <environment>      # also check env vars
#
#   environment: local | staging | prod
#
# Examples:
#   ./scripts/validate.sh                    # CI / general check
#   ./scripts/validate.sh staging            # pre-deploy check

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

# ── Optional environment argument ────────────────────────────
TARGET_ENV="${1:-}"

if [[ -n "$TARGET_ENV" ]]; then
  case "$TARGET_ENV" in
    local|staging|prod) ;;
    *)
      echo "ERROR: unknown environment '$TARGET_ENV'. Use 'local', 'staging', or 'prod'."
      exit 1
      ;;
  esac
fi

# ── Resolve infra root ──────────────────────────────────────
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA_DIR"

echo ""
echo "=== Validate infra configs ==="
echo ""

# ── Dummy env vars for docker compose config ────────────────
# Dynamically extract all ${VAR} references from docker-compose.yml
# and set any undefined ones to a placeholder value.
# This way we never need to maintain a manual list.
while IFS= read -r var; do
  if [[ -z "${!var:-}" ]]; then
    export "$var=8080"
  fi
done < <(grep -oP '\$\{(\w+)' docker-compose.yml | sed 's/\${//' | sort -u)

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

# ── 5. Grafana provisioning (YAML) ──────────────────────────
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

# ── 6. ShellCheck ────────────────────────────────────────────
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

# ── 7. Production release version in manifest ───────────────
echo ""
echo "Production manifest:"

PROD_MANIFEST="environments/production.manifest.env"
IMAGES_MANIFEST="environments/images.manifest.env"
STAGING_CONFIG="environments/staging.config.env"
PRODUCTION_CONFIG="environments/production.config.env"
if [[ ! -f "$PROD_MANIFEST" ]]; then
  fail "$PROD_MANIFEST not found"
else
  RELEASE_VERSION_LINE=$(grep -E '^RELEASE_VERSION=' "$PROD_MANIFEST" || true)
  if [[ -z "$RELEASE_VERSION_LINE" ]]; then
    fail "RELEASE_VERSION is missing in $PROD_MANIFEST"
  else
    RELEASE_VERSION="${RELEASE_VERSION_LINE#*=}"
    if [[ "$RELEASE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      pass "RELEASE_VERSION format is valid ($RELEASE_VERSION)"
    else
      fail "RELEASE_VERSION must match vX.Y.Z in $PROD_MANIFEST"
    fi
  fi

fi

echo ""
echo "Shared images manifest:"

if [[ ! -f "$IMAGES_MANIFEST" ]]; then
  fail "$IMAGES_MANIFEST not found"
else
  for key in POSTGRES_IMAGE MINIO_IMAGE REDIS_IMAGE PROMETHEUS_IMAGE GRAFANA_IMAGE; do
    if grep -qE "^${key}=.+" "$IMAGES_MANIFEST"; then
      pass "${key} is present in $IMAGES_MANIFEST"
    else
      fail "${key} is missing in $IMAGES_MANIFEST"
    fi
  done
fi

echo ""
echo "Runtime config manifests:"

validate_config_file() {
  local file="$1"
  local label="$2"
  shift 2
  local expected_keys=("$@")

  if [[ ! -f "$file" ]]; then
    fail "$file not found"
    return
  fi

  for key in "${expected_keys[@]}"; do
    if grep -qE "^${key}=.+" "$file"; then
      pass "${label}: ${key} is present"
    else
      fail "${label}: ${key} is missing in $file"
    fi
  done

  for secret_key in DB_PASSWORD JWT_SECRET MINIO_ROOT_USER MINIO_ROOT_PASSWORD SMTP_USERNAME SMTP_PASSWORD REDIS_PASSWORD; do
    if grep -qE "^${secret_key}=SECRET_IN_GITHUB_ENV$" "$file"; then
      pass "${label}: ${secret_key} placeholder is explicit"
    elif grep -qE "^${secret_key}=" "$file"; then
      fail "${label}: ${secret_key} must use SECRET_IN_GITHUB_ENV placeholder in $file"
    else
      fail "${label}: ${secret_key} placeholder is missing in $file"
    fi
  done
}

COMMON_CONFIG_KEYS=(
  FRONTEND_PORT
  DB_USER
  DB_NAME
  BACKEND_HOST
  BACKEND_PORT
  JWT_TOKEN_DURATION
  JWT_REFRESH_TOKEN_DURATION
  CORS_ORIGINS
  LOG_LEVEL
  LOG_FORMAT
  GIN_MODE
  RATE_LIMIT_IP_MAX
  RATE_LIMIT_IP_WINDOW
  RATE_LIMIT_USER_MAX
  RATE_LIMIT_USER_WINDOW
  LOGIN_THROTTLE_MAX_ATTEMPTS
  LOGIN_THROTTLE_WINDOW
  LOGIN_THROTTLE_LOCKOUT
  MINIO_BUCKET
  MINIO_CONSOLE_PORT
  SMTP_HOST
  SMTP_PORT
  SMTP_AUTH
  SMTP_FROM
  REDIS_HOST
  REDIS_PORT
  REDIS_AUTH
  REDIS_DB
  GRAFANA_PORT
  PROMETHEUS_RETENTION
  VERIFICATION_BASE_URL
  VERIFICATION_EMAIL_TOKEN_TTL
  VERIFICATION_PASSWORD_RESET_TOKEN_TTL
)

validate_config_file "$STAGING_CONFIG" "staging.config.env" ENV "${COMMON_CONFIG_KEYS[@]}"
validate_config_file "$PRODUCTION_CONFIG" "production.config.env" ENV "${COMMON_CONFIG_KEYS[@]}"

# ── 8. Environment variables completeness ───────────────────
if [[ -n "$TARGET_ENV" ]]; then
  echo ""
  echo "Environment variables ($TARGET_ENV):"

  EXAMPLE_FILE=".env.example"
  ACTUAL_FILE=".env.${TARGET_ENV}"

  if [[ ! -f "$EXAMPLE_FILE" ]]; then
    fail "$EXAMPLE_FILE not found"
  elif [[ ! -f "$ACTUAL_FILE" ]]; then
    fail "$ACTUAL_FILE not found — copy from $EXAMPLE_FILE and fill in values"
  else
    MISSING_VARS=()
    EMPTY_VARS=()

    # Extract variable names from example (lines matching KEY=VALUE, skip comments/blanks)
    while IFS='=' read -r key _; do
      # Look up value in actual env file
      ACTUAL_LINE=$(grep -E "^${key}=" "$ACTUAL_FILE" 2>/dev/null || true)
      if [[ -z "$ACTUAL_LINE" ]]; then
        MISSING_VARS+=("$key")
      else
        VALUE="${ACTUAL_LINE#*=}"
        if [[ -z "$VALUE" ]]; then
          EMPTY_VARS+=("$key")
        fi
      fi
    done < <(grep -E '^[A-Z_]+=.' "$EXAMPLE_FILE")

    if [[ ${#MISSING_VARS[@]} -eq 0 && ${#EMPTY_VARS[@]} -eq 0 ]]; then
      pass "All variables from $EXAMPLE_FILE are defined in $ACTUAL_FILE"
    else
      if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
        fail "Missing variables in $ACTUAL_FILE: ${MISSING_VARS[*]}"
      fi
      if [[ ${#EMPTY_VARS[@]} -gt 0 ]]; then
        fail "Empty variables in $ACTUAL_FILE: ${EMPTY_VARS[*]}"
      fi
    fi
  fi
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "${GREEN}All checks passed.${NC}"
else
  echo -e "${RED}${FAILURES} check(s) failed.${NC}"
  exit 1
fi
