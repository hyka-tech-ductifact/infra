#!/usr/bin/env bash
# validate_env.sh — Validate a runtime env file against .env.example.
#
# Run automatically by deploy.sh before every deploy.
# Run locally to verify .env.<environment> is complete before deploying.
#
# Usage:
#   ./scripts/validate_env.sh <environment>
#
#   environment: local | staging | prod
#
# What it checks:
#   - .env.<environment> exists
#   - Every variable defined in .env.example is present and non-empty in .env.<environment>

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; FAILURES=$((FAILURES + 1)); }

FAILURES=0
ENV="${1:-}"

if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <local|staging|prod>"
  exit 1
fi

case "$ENV" in
  local|staging|prod) ;;
  *)
    echo "ERROR: unknown environment '$ENV'. Use 'local', 'staging', or 'prod'."
    exit 1
    ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA_DIR"

EXAMPLE_FILE=".env.example"
ACTUAL_FILE=".env.${ENV}"

echo ""
echo "=== validate_env ($ENV) ==="
echo ""

if [[ ! -f "$EXAMPLE_FILE" ]]; then
  echo "ERROR: $EXAMPLE_FILE not found."
  exit 1
fi

if [[ ! -f "$ACTUAL_FILE" ]]; then
  fail "$ACTUAL_FILE not found — copy from $EXAMPLE_FILE and fill in values"
  echo ""
  echo -e "${RED}1 check(s) failed.${NC}"
  exit 1
fi

missing_vars=()
empty_vars=()

while IFS='=' read -r key _; do
  actual_line=$(grep -E "^${key}=" "$ACTUAL_FILE" 2>/dev/null || true)
  if [[ -z "$actual_line" ]]; then
    missing_vars+=("$key")
  else
    value="${actual_line#*=}"
    if [[ -z "$value" ]]; then
      empty_vars+=("$key")
    fi
  fi
done < <(grep -E '^[A-Z_]+=.' "$EXAMPLE_FILE")

if [[ ${#missing_vars[@]} -eq 0 && ${#empty_vars[@]} -eq 0 ]]; then
  pass "All variables from $EXAMPLE_FILE are present and non-empty in $ACTUAL_FILE"
else
  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    fail "Missing in $ACTUAL_FILE: ${missing_vars[*]}"
  fi
  if [[ ${#empty_vars[@]} -gt 0 ]]; then
    fail "Empty in $ACTUAL_FILE: ${empty_vars[*]}"
  fi
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "${GREEN}All env checks passed.${NC}"
else
  echo -e "${RED}${FAILURES} check(s) failed.${NC}"
  exit 1
fi
