#!/usr/bin/env bash
# Validate repository configuration and generated environments.
# Runs on: GitHub Actions runner, or developer machine.
# Called by: PR workflow or operator.
# Calls: ops/generate_env.sh (with dummy CI secrets).
# Usage: ./scripts/ci/check_repo.sh

set -euo pipefail

command -v jq >/dev/null || { echo "ERROR: jq is required for JSON validation" >&2; exit 1; }

# ── Helpers: report validation results ───────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${YELLOW}…${NC} $1"; }

FAILURES=0
INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$INFRA_DIR"

echo ""
echo "=== validate_repo ==="
echo ""

# Compose is checked below with each generated environment, not invented defaults.

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
      if jq empty "$f" > /dev/null 2>&1; then
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
  for f in scripts/{ci,ops,checks}/*.sh; do
    if shellcheck "$f" > /dev/null 2>&1; then
      pass "$(basename "$f") passes shellcheck"
    else
      fail "$(basename "$f") has shellcheck warnings"
    fi
  done
fi

# ── Derive key sets from .env.contract (single source of truth) ───────────────
CONTRACT_FILE=".env.contract"

if [[ ! -f "$CONTRACT_FILE" ]]; then
  echo "ERROR: $CONTRACT_FILE not found — cannot derive expected keys."
  exit 1
fi

# Keys whose value in .env.contract is SECRET_IN_GITHUB_ENV
mapfile -t SECRET_KEYS < <(grep -E '^[A-Z_][A-Z0-9_]*=SECRET_IN_GITHUB_ENV$' "$CONTRACT_FILE" | cut -d= -f1)

# Platform image keys: *_IMAGE entries that are NOT local-only (BACKEND_IMAGE, FRONTEND_IMAGE)
LOCAL_ONLY_IMAGE_KEYS=(BACKEND_IMAGE FRONTEND_IMAGE)
mapfile -t PLATFORM_IMAGE_KEYS < <(
  grep -E '^[A-Z_][A-Z0-9_]*_IMAGE=' "$CONTRACT_FILE" | cut -d= -f1 | grep -vxFf <(printf '%s\n' "${LOCAL_ONLY_IMAGE_KEYS[@]}")
)

# Config keys: all non-comment keys that are not secrets, not images (platform or local-only)
ALL_EXCLUDE_KEYS=("${SECRET_KEYS[@]}" "${LOCAL_ONLY_IMAGE_KEYS[@]}" "${PLATFORM_IMAGE_KEYS[@]}")
mapfile -t CONFIG_KEYS < <(
  grep -E '^[A-Z_][A-Z0-9_]*=' "$CONTRACT_FILE" | cut -d= -f1 | grep -vxFf <(printf '%s\n' "${ALL_EXCLUDE_KEYS[@]}")
)

# ── 5. Shared images manifest ─────────────────────────────────
echo ""
echo "Shared images manifest (environments/images.manifest.env):"

IMAGES_MANIFEST="environments/images.manifest.env"
if [[ ! -f "$IMAGES_MANIFEST" ]]; then
  fail "$IMAGES_MANIFEST not found"
else
  images_failures=0
  for key in "${PLATFORM_IMAGE_KEYS[@]}"; do
    if ! grep -qE "^${key}=.+" "$IMAGES_MANIFEST"; then
      fail "${key} is missing in $IMAGES_MANIFEST"
      images_failures=$((images_failures + 1))
    fi
  done
  if [[ "$images_failures" -eq 0 ]]; then
    pass "all platform image keys present"
  fi
fi

# ── 6. Runtime config manifests ───────────────────────────────
echo ""
echo "Runtime config manifests (environments/*.config.env):"

check_config_file() {
  local file="$1"
  local label="$2"
  local local_failures=0

  if [[ ! -f "$file" ]]; then
    fail "$label: $file not found"
    return
  fi

  for key in "${CONFIG_KEYS[@]}"; do
    if ! grep -qE "^${key}=.+" "$file"; then
      fail "$label: $key is missing"
      local_failures=$((local_failures + 1))
    fi
  done

  for key in "${SECRET_KEYS[@]}"; do
    if [[ "$label" == "local.config.env" ]] && grep -qE "^${key}=.+" "$file"; then
      : # Local-only development credentials are versioned defaults.
    elif grep -qE "^${key}=SECRET_IN_GITHUB_ENV$" "$file"; then
      : # ok
    elif grep -qE "^${key}=" "$file"; then
      fail "$label: $key must be SECRET_IN_GITHUB_ENV (not a real value)"
      local_failures=$((local_failures + 1))
    else
      fail "$label: $key placeholder is missing"
      local_failures=$((local_failures + 1))
    fi
  done

  if [[ "$local_failures" -eq 0 ]]; then
    pass "$label: all keys present and valid"
  fi
}

check_config_file "environments/local.config.env"      "local.config.env"
check_config_file "environments/staging.config.env"    "staging.config.env"
check_config_file "environments/production.config.env" "production.config.env"

# ── 6b. Secret whitelist — scan all environments/* for leaked secrets ─────────
echo ""
echo "Secret whitelist (environments/*):"

leaked=0
while IFS= read -r -d '' file; do
  [[ "$file" == "environments/local.config.env" ]] && continue
  for key in "${SECRET_KEYS[@]}"; do
    while IFS='=' read -r _ value; do
      if [[ "$value" != SECRET_IN_GITHUB_ENV ]]; then
        fail "$(basename "$file"): $key must be SECRET_IN_GITHUB_ENV"
        leaked=$((leaked + 1))
      fi
    done < <(grep -E "^${key}=" "$file" || true)
  done
done < <(find environments/ -type f -name '*.env' -print0)

if [[ "$leaked" -eq 0 ]]; then
  pass "no real secret values found outside local development defaults"
fi

# ── Generate runtime files and validate Compose ──────────────────────
# Generate and validate each environment with dummy CI secrets; no SSH or deploy.
ENV_CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$ENV_CHECK_DIR"' EXIT
for key in "${SECRET_KEYS[@]}"; do
  export "$key=ci-validation-only"
done
for environment in local staging production; do
  if ./scripts/ops/generate_env.sh "$environment" --output "${ENV_CHECK_DIR}/.env.${environment}"; then
    # Compose gives inherited shell variables precedence; check the file itself.
    if (
      runtime_file="${ENV_CHECK_DIR}/.env.${environment}"
      while IFS='=' read -r key _; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && unset "$key"
      done < "$runtime_file"
      docker compose --env-file "$runtime_file" config --quiet
    ); then
      pass "$environment runtime file and Compose configuration are valid"
    else
      fail "$environment Compose configuration is invalid"
    fi
  else
    fail "$environment runtime generation failed"
  fi
done

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
    version="${release_version_line#*=}"
    if [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?(\+[a-zA-Z0-9._-]+)?$ ]]; then
      pass "RELEASE_VERSION is valid semver ($version)"
    else
      fail "RELEASE_VERSION is not valid semver: '$version' (expected vMAJOR.MINOR.PATCH)"
    fi
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
