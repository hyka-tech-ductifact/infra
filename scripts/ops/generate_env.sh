#!/usr/bin/env bash
# Build and validate a runtime .env.<environment> file.
# Runs on: Developer machine or GitHub Actions runner.
# Called by: Operator, ci/check_repo.sh, or ci/deploy_remote.sh.
# Calls: checks/env.sh.
# Usage: ./scripts/ops/generate_env.sh <local|staging|production> [--output PATH] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV="${1:-}"
case "$ENV" in
  local|staging|production) shift ;;
  *) echo "Usage: $0 <local|staging|production> [--output PATH] [--force]"; exit 1 ;;
esac

OUTPUT="${INFRA_DIR}/.env.${ENV}"
FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --output needs a path"; exit 1; }
      OUTPUT="$2"
      shift 2
      ;;
    --force) FORCE=true; shift ;;
    *) echo "ERROR: unknown option '$1'"; exit 1 ;;
  esac
done

if [[ -e "$OUTPUT" && "$FORCE" == false ]]; then
  echo "ERROR: $OUTPUT already exists. Edit it directly, or use --force to replace it with the versioned defaults."
  exit 1
fi

INPUTS=(
  "${INFRA_DIR}/environments/${ENV}.config.env"
  "${INFRA_DIR}/environments/${ENV}.manifest.env"
  "${INFRA_DIR}/environments/images.manifest.env"
)
for file in "${INPUTS[@]}"; do
  [[ -f "$file" ]] || { echo "ERROR: input file not found: $file"; exit 1; }
done

umask 077
TMP_FILE="$(mktemp "${OUTPUT}.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

# Copy inputs as data. Only CI secret placeholders need substitution.
for file in "${INPUTS[@]}"; do
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=SECRET_IN_GITHUB_ENV$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${!key:-}"
      if [[ "$ENV" == local || -z "$value" || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        echo "ERROR: $key needs a non-empty, single-line CI secret" >&2
        exit 1
      fi
      # Compose single quotes keep $, backticks, spaces and # literal.
      value="${value//\'/\\\'}"
      printf "%s='%s'\n" "$key" "$value"
    else
      printf '%s\n' "$line"
    fi
  done < "$file"
  printf '\n'
done > "$TMP_FILE"

"${SCRIPT_DIR}/../checks/env.sh" "$ENV" --file "$TMP_FILE"
if [[ "$FORCE" == true ]]; then
  mv -f "$TMP_FILE" "$OUTPUT"
else
  # Exclusive creation also avoids overwriting a concurrently created file.
  ln "$TMP_FILE" "$OUTPUT"
fi
echo "Generated $OUTPUT (permissions 600)"
