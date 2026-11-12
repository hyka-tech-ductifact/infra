#!/usr/bin/env bash
# Exercise registration and the API user journey with a fresh test email.
# Runs on: Machine running the target containers; requires curl and jq.
# Called by: Operator explicitly; prompts for the registration code received by email.
# Calls: No other repository scripts. Removes created resources/account on exit.
# Usage: ./scripts/checks/user_flow.sh <local|staging|production> <test-email>

set -euo pipefail

# ── Validate arguments ───────────────────────────────────────────────
ENV="${1:-}"
EMAIL="${2:-}"
if [[ $# -ne 2 || -z "$EMAIL" ]]; then
  echo "Usage: $0 <local|staging|production> <fresh-test-email>"
  exit 1
fi
case "$ENV" in
  local|staging|production) ;;
  *) echo "ERROR: unknown environment '$ENV'" >&2; exit 1 ;;
esac
command -v jq >/dev/null || { echo 'ERROR: jq is required' >&2; exit 1; }

# ── Load environment ─────────────────────────────────────────────────
INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${INFRA_DIR}/.env.${ENV}"
ENV_VALUES="$(docker compose --project-directory "$INFRA_DIR" --env-file "$ENV_FILE" config --environment)"
while IFS='=' read -r key value; do
  [[ "$key" != BACKEND_PORT ]] || BACKEND_PORT="$value"
done <<< "$ENV_VALUES"
unset ENV_VALUES
ORIGIN="http://localhost:${BACKEND_PORT:?BACKEND_PORT is required}"
BASE_URL="$ORIGIN/v1"

# ── Prepare temporary files ──────────────────────────────────────────
umask 077
WORK_DIR="$(mktemp -d)"
RESPONSE_FILE="$WORK_DIR/response.json"
AUTH_HEADERS=()
CREATED_PATHS=()
TOKEN=""

# ── Helper: clean up test resources ──────────────────────────────────
# Clean up only resources created by this run, in reverse dependency order.
cleanup() {
  local result=$? index status path
  trap - EXIT
  if [[ -n "$TOKEN" ]]; then
    for ((index = ${#CREATED_PATHS[@]} - 1; index >= 0; index--)); do
      path="${CREATED_PATHS[index]}"
      status=$(curl -sS --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' \
        -X DELETE "${AUTH_HEADERS[@]}" "$BASE_URL$path") || status=000
      if [[ "$status" != 204 && "$status" != 404 ]]; then
        echo "ERROR: cleanup failed for $path (HTTP $status)" >&2
        result=1
      fi
    done
    status=$(curl -sS --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' \
      -X DELETE "${AUTH_HEADERS[@]}" "$BASE_URL/users/me?cascade=true") || status=000
    if [[ "$status" != 200 ]]; then
      echo "ERROR: test account cleanup failed (HTTP $status); check $EMAIL" >&2
      result=1
    fi
  fi
  rm -rf "$WORK_DIR"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── Helpers: HTTP requests and JSON responses ────────────────────────
# Keep HTTP status and JSON body separate. A failed prerequisite stops the flow.
request() {
  local method="$1" url="$2" expected="$3" status
  shift 3
  status=$(curl -sS --connect-timeout 5 --max-time 20 -o "$RESPONSE_FILE" -w '%{http_code}' \
    -X "$method" "${AUTH_HEADERS[@]}" "$@" "$url") || {
      echo "ERROR: $method request failed" >&2
      return 1
    }
  if [[ "$status" != "$expected" ]]; then
    echo "ERROR: $method $url expected HTTP $expected, received $status" >&2
    return 1
  fi
  echo "PASS: $method $url (HTTP $status)"
}

field() {
  jq -er --arg key "$1" '.[$key] | select(type == "string" and length > 0)' "$RESPONSE_FILE"
}

create_json() {
  request POST "$BASE_URL$1" 201 -H 'Content-Type: application/json' -d "$2"
}

remember_resource() {
  local collection="$1"
  RESOURCE_ID=$(field id)
  CREATED_PATHS+=("$collection/$RESOURCE_ID")
}

# ── 1. Register and verify the test account ──────────────────────────
# Registration now has two steps. Use an inbox you can read (or a local SMTP inbox).
request POST "$BASE_URL/auth/register" 200 -H 'Content-Type: application/json' \
  -d "$(jq -n --arg email "$EMAIL" '{email: $email}')"
read -rp "Registration code sent to $EMAIL: " REGISTRATION_CODE
TEST_PASSWORD="Flow-${RANDOM}-${RANDOM}-aA9!"
create_json /auth/register/verify "$(jq -n --arg email "$EMAIL" --arg code "$REGISTRATION_CODE" \
  --arg password "$TEST_PASSWORD" '{email: $email, code: $code, name: "Flow Test User", password: $password}')"
TOKEN=$(field access_token)
AUTH_HEADERS=(-H "Authorization: Bearer $TOKEN")

# ── 2. Create client ─────────────────────────────────────────────────
create_json /clients '{"name":"Flow Test Client","phone":"+34 600 000 001","email":"client@flow.test","description":"Created by user_flow.sh"}'
remember_resource /clients
CLIENT_ID="$RESOURCE_ID"

# ── 3. Create project ────────────────────────────────────────────────
create_json "/clients/$CLIENT_ID/projects" '{"name":"Flow Test Project","address":"Test address","manager_name":"Flow Manager"}'
remember_resource /projects
PROJECT_ID="$RESOURCE_ID"

# ── 4. Create piece definition with image ────────────────────────────
# A small PNG fixture, removed together with the response file on exit.
PNG_FILE="$WORK_DIR/image.png"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==' | base64 -d > "$PNG_FILE"
request POST "$BASE_URL/piece-definitions" 201 \
  -F 'data={"name":"Flow Rectangle","dimension_schema":["Length","Width"]}' \
  -F "image=@${PNG_FILE};type=image/png"
remember_resource /piece-definitions
PIECEDEF_ID="$RESOURCE_ID"
IMAGE_URL=$(field image_url)
THUMBNAIL_URL=$(field thumbnail_url)
# ── 5. Verify images through the file proxy ──────────────────────────
for path in "$IMAGE_URL" "$THUMBNAIL_URL"; do
  [[ "$path" == /v1/files/* ]] || { echo 'ERROR: unexpected file proxy path' >&2; exit 1; }
  request GET "$ORIGIN$path" 200
done

# ── 6. Create order ──────────────────────────────────────────────────
create_json "/projects/$PROJECT_ID/orders" '{"title":"Flow Test Order"}'
remember_resource /orders
ORDER_ID="$RESOURCE_ID"

# ── 7. Create piece ──────────────────────────────────────────────────
create_json "/orders/$ORDER_ID/pieces" "$(jq -n --arg definition "$PIECEDEF_ID" \
  '{title: "Side Panel", definition_id: $definition, dimensions: {Length: 150.5, Width: 80}, quantity: 10}')"
remember_resource "/orders/$ORDER_ID/pieces"

# ── 8. Verify created resources ──────────────────────────────────────
for path in "${CREATED_PATHS[@]}"; do
  request GET "$BASE_URL$path" 200
done

# ── Summary and automatic cleanup ────────────────────────────────────
echo 'API flow checks passed. Removing test resources and account...'
