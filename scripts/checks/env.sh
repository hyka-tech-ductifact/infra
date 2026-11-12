#!/usr/bin/env bash
# Check runtime variables against .env.contract.
# Runs on: Developer machine, CI runner, or target server.
# Called by: ops/generate_env.sh, ops/deploy.sh, or operator.
# Calls: No other repository scripts; no connectivity checks.
# Usage: ./scripts/checks/env.sh <local|staging|production> [--file PATH]

set -euo pipefail

# ── Validate arguments and input files ───────────────────────────────
INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV="${1:-}"
case "$ENV" in
  local|staging|production) shift ;;
  *) echo "Usage: $0 <local|staging|production> [--file PATH]"; exit 1 ;;
esac
ACTUAL_FILE="${INFRA_DIR}/.env.${ENV}"
if [[ $# -gt 0 ]]; then
  [[ $# -eq 2 && "$1" == --file ]] || { echo "ERROR: expected --file PATH"; exit 1; }
  ACTUAL_FILE="$2"
fi
CONTRACT_FILE="${INFRA_DIR}/.env.contract"
for file in "$CONTRACT_FILE" "$ACTUAL_FILE"; do
  [[ -f "$file" ]] || { echo "ERROR: file not found: $file"; exit 1; }
done

# ── Helpers: report errors and parse values ──────────────────────────
# Keep parsing, value checks, and required-key checks separate.
# This accepts single-line KEY=VALUE entries; it never executes their contents.
declare -A values=()
failures=0

fail() {
  printf 'ERROR: %s: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

trim() {
  REPLY="${1#"${1%%[![:blank:]]*}"}"
  REPLY="${REPLY%"${REPLY##*[![:blank:]]}"}"
}

parse_value() {
  local text="$1" quote character suffix index
  trim "$text"
  text="$REPLY"
  quote="${text:0:1}"

  if [[ "$quote" != "'" && "$quote" != '"' ]]; then
    # Only whitespace followed by # starts an unquoted inline comment.
    text="${text%%[[:blank:]]#*}"
    trim "$text"
    return 0
  fi

  # Find the closing quote without treating an escaped quote as the end.
  for ((index = 1; index < ${#text}; index++)); do
    character="${text:index:1}"
    if [[ "$character" == \\ ]]; then
      index=$((index + 1))
    elif [[ "$character" == "$quote" ]]; then
      suffix="${text:index+1}"
      trim "$suffix"
      [[ -z "$REPLY" || "$REPLY" == \#* ]] || return 1
      REPLY="${text:1:index-1}"
      return 0
    fi
  done
  return 1
}

# ── Helpers: validate variable values ────────────────────────────────
is_integer() {
  [[ "$1" =~ ^[0-9]+$ && ${#1} -le 12 ]]
}

check_value() {
  local key="$1" value="$2"
  if [[ ! "$value" =~ [^[:blank:]] ]]; then
    fail "$key" 'must not be empty'
    return
  fi
  if [[ "$value" == *SECRET_IN_GITHUB_ENV* || "$value" == *CHANGE_ME* ]]; then
    fail "$key" 'unresolved placeholder'
    return
  fi

  case "$key" in
    ENV)
      [[ "$value" == "$ENV" ]] || fail "$key" "must match $ENV"
      ;;
    *_PORT)
      if ! is_integer "$value" || ((10#$value < 1 || 10#$value > 65535)); then
        fail "$key" 'must be a port between 1 and 65535'
      fi
      ;;
    *_SECONDS|*_MAX|*_MAX_ATTEMPTS)
      if ! is_integer "$value" || ((10#$value < 1)); then
        fail "$key" 'must be a positive integer'
      fi
      ;;
    REDIS_DB)
      is_integer "$value" || fail "$key" 'must be a non-negative integer'
      ;;
    SMTP_AUTH|REDIS_AUTH)
      [[ "$value" == true || "$value" == false ]] || fail "$key" 'must be true or false'
      ;;
    PUBLIC_BACKEND_URL|PUBLIC_FILE_STORAGE_URL)
      [[ "$value" =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]] || fail "$key" 'must be an absolute http(s) URL'
      ;;
    *_IMAGE)
      [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]] || fail "$key" 'invalid image reference'
      if [[ "$value" == *@* && ! "$value" =~ ^[^@]+@sha256:[a-fA-F0-9]{64}$ ]]; then
        fail "$key" 'invalid sha256 digest'
      fi
      ;;
  esac
}

# ── Read and validate runtime variables ──────────────────────────────
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_number=$((line_number + 1))
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:blank:]]*(#|$) ]] && continue
  if [[ ! "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
    fail "line $line_number" 'expected KEY=VALUE'
    continue
  fi
  key="${BASH_REMATCH[1]}"
  raw_value="${BASH_REMATCH[2]}"
  if [[ -v "values[$key]" ]]; then
    fail "$key" 'duplicate variable'
  fi
  values["$key"]="$raw_value"
  if parse_value "$raw_value"; then
    check_value "$key" "$REPLY"
  else
    fail "$key" 'unclosed quote or unexpected text after quoted value'
  fi
done < "$ACTUAL_FILE"

# ── Check required variables ─────────────────────────────────────────
required_count=0
while IFS='=' read -r key _ || [[ -n "$key" ]]; do
  [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
  required_count=$((required_count + 1))
  [[ -v "values[$key]" ]] || fail "$key" 'missing required variable'
done < "$CONTRACT_FILE"
((required_count > 0)) || fail '.env.contract' 'contains no required variables'
# ── Summary ──────────────────────────────────────────────────────────
((failures == 0)) || exit 1
printf 'All env checks passed (%s).\n' "$ENV"
