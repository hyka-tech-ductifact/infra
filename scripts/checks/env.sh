#!/usr/bin/env bash
# Check runtime variables against .env.contract.
# Runs on: Developer machine, CI runner, or target server.
# Called by: ops/generate_env.sh, ops/deploy.sh, or operator.
# Calls: No other repository scripts; no connectivity checks.
# Usage: ./scripts/checks/env.sh <local|staging|production> [--file PATH]

set -euo pipefail

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

# Only inspect scalar values. Never source the file or print its values.
awk -v environment="$ENV" '
function fail(key, message) {
  print "ERROR: " key ": " message > "/dev/stderr"
  failures++
}
NR == FNR {
  if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
    split($0, entry, "=")
    required[entry[1]] = 1
  }
  next
}
/^[[:space:]]*($|#)/ { next }
{
  if (!match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
    fail("line " FNR, "expected KEY=VALUE")
    next
  }
  key = substr($0, 1, RLENGTH - 1)
  value = substr($0, RLENGTH + 1)
  if (seen[key]++) fail(key, "duplicate variable")
  sub(/[ \t]+#.*/, "", value)
  gsub(/^[ \t]+|[ \t]+$/, "", value)
  quote = substr(value, 1, 1)
  if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(value, length(value), 1) == quote)
    value = substr(value, 2, length(value) - 2)

  if (value ~ /^[ \t]*$/) fail(key, "must not be empty")
  else if (value ~ /SECRET_IN_GITHUB_ENV|CHANGE_ME/)
    fail(key, "unresolved placeholder")
  else if (key == "ENV" && value != environment) fail(key, "does not match " environment)
  else if (key ~ /_PORT$/) {
    if (value !~ /^[0-9]+$/ || length(value) > 5 || value + 0 < 1 || value + 0 > 65535)
      fail(key, "must be a port between 1 and 65535")
  } else if (key ~ /_SECONDS$|_MAX$|_MAX_ATTEMPTS$/ || key == "REDIS_DB") {
    if (value !~ /^[0-9]+$/ || length(value) > 12 || value + 0 < (key == "REDIS_DB" ? 0 : 1))
      fail(key, "must be a positive integer (REDIS_DB also allows zero)")
  } else if (key == "SMTP_AUTH" || key == "REDIS_AUTH") {
    if (value != "true" && value != "false") fail(key, "must be true or false")
  } else if (key == "PUBLIC_BACKEND_URL" || key == "PUBLIC_FILE_STORAGE_URL") {
    if (value !~ /^https?:\/\/[^/[:space:]]+(\/[^[:space:]]*)?$/) fail(key, "must be an absolute http(s) URL")
  } else if (key ~ /_IMAGE$/) {
    if (value !~ /^[A-Za-z0-9][A-Za-z0-9._\/:@-]*$/) fail(key, "invalid image reference")
    if (index(value, "@")) {
      split(value, image, "@sha256:")
      if (length(image[2]) != 64 || image[2] ~ /[^a-fA-F0-9]/) fail(key, "invalid sha256 digest")
    }
  }
}
END {
  for (key in required) if (!(key in seen)) fail(key, "missing required variable")
  if (failures) exit 1
  print "All env checks passed (" environment ")."
}
' "$CONTRACT_FILE" "$ACTUAL_FILE"
