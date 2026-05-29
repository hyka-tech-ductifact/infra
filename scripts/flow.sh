#!/usr/bin/env bash
# flow.sh — Full user-flow smoke test for a ductifact environment.
#
# Simulates a complete new-user journey through the entire API:
#   1. Register a new user
#   2. Create a client
#   3. Create a project under the client
#   4. Create a piece definition with an image
#   5. Verify the image is served via file proxy
#   6. Create an order under the project
#   7. Create a piece in the order (linked to the definition)
#   8. Verify everything is retrievable
#   9. Clean up: delete all created resources
#
# Usage:
#   ./scripts/flow.sh <environment>
#
#   environment: local | staging | production
#   alias: prod -> production
#
# Examples:
#   ./scripts/flow.sh local
#   ./scripts/flow.sh staging

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; FAILURES=$((FAILURES + 1)); }
step() { echo -e "\n${CYAN}── $1${NC}"; }

FAILURES=0

# ── Validate arguments ──────────────────────────────────────
ENV="${1:-}"

if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <environment>"
  echo "  environment: local | staging | production"
  exit 1
fi

case "$ENV" in
  prod) ENV="production" ;;
  local|staging|production) ;;
  *)
    echo "ERROR: unknown environment '$ENV'. Use 'local', 'staging', or 'production'."
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

BASE_URL="http://localhost:${BACKEND_PORT}/v1"
TIMESTAMP=$(date +%s)
EMAIL="flow-${TIMESTAMP}@test.ductifact.dev"

echo ""
echo "=== Full user-flow test for '$ENV' ==="
echo "    Base URL: $BASE_URL"
echo "    User:     $EMAIL"

# ── Helper: make API calls and extract fields ───────────────

# json_field extracts a field from a JSON string.
# Usage: json_field '{"id":"abc"}' "id" → abc
json_field() {
  echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# assert_status checks the HTTP status code.
# Usage: assert_status "$RESPONSE" 201 "create client"
assert_status() {
  local status="$1" expected="$2" label="$3"
  if [[ "$status" == "$expected" ]]; then
    pass "$label → $status"
  else
    fail "$label → expected $expected, got $status"
  fi
}

# ── 1. Register ─────────────────────────────────────────────
step "1. Register user"

REGISTER_RESPONSE=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"Flow Test User\",\"email\":\"$EMAIL\",\"password\":\"securepass123\"}" 2>&1) || true

REGISTER_STATUS=$(echo "$REGISTER_RESPONSE" | tail -1)
REGISTER_BODY=$(echo "$REGISTER_RESPONSE" | sed '$d')
assert_status "$REGISTER_STATUS" "201" "Register user"

TOKEN=$(json_field "$REGISTER_BODY" "access_token")
if [[ -z "$TOKEN" ]]; then
  echo -e "${RED}FATAL: No token obtained. Cannot continue.${NC}"
  exit 1
fi
pass "Token obtained"

# Authenticated curl shortcut
auth_get()  { curl -sf -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" "$1" 2>&1 || true; }
auth_post() { curl -sf -w "\n%{http_code}" -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$2" "$1" 2>&1 || true; }
auth_del()  { curl -sf -w "\n%{http_code}" -X DELETE -H "Authorization: Bearer $TOKEN" "$1" 2>&1 || true; }

# ── 2. Create client ────────────────────────────────────────
step "2. Create client"

CLIENT_RESPONSE=$(auth_post "$BASE_URL/clients" \
  '{"name":"Flow Test Client","phone":"+34 600 000 001","email":"client@flow.test","description":"Created by flow.sh"}')

CLIENT_STATUS=$(echo "$CLIENT_RESPONSE" | tail -1)
CLIENT_BODY=$(echo "$CLIENT_RESPONSE" | sed '$d')
assert_status "$CLIENT_STATUS" "201" "Create client"

CLIENT_ID=$(json_field "$CLIENT_BODY" "id")
pass "Client ID: $CLIENT_ID"

# ── 3. Create project ───────────────────────────────────────
step "3. Create project under client"

PROJECT_RESPONSE=$(auth_post "$BASE_URL/clients/$CLIENT_ID/projects" \
  '{"name":"Flow Test Project","address":"Calle Test 1","manager_name":"Flow Manager","description":"Created by flow.sh"}')

PROJECT_STATUS=$(echo "$PROJECT_RESPONSE" | tail -1)
PROJECT_BODY=$(echo "$PROJECT_RESPONSE" | sed '$d')
assert_status "$PROJECT_STATUS" "201" "Create project"

PROJECT_ID=$(json_field "$PROJECT_BODY" "id")
pass "Project ID: $PROJECT_ID"

# ── 4. Create piece definition with image ───────────────────
step "4. Create piece definition with image"

# Minimal valid 1×1 PNG (base64-encoded to avoid shell byte-mangling)
PNG_FILE=$(mktemp /tmp/flow-test-XXXXXX.png)
echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==" \
  | base64 -d > "$PNG_FILE"

PIECEDEF_RESPONSE=$(curl -sf -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -F "data={\"name\":\"Flow Rectangle\",\"dimension_schema\":[\"Length\",\"Width\"]}" \
  -F "image=@${PNG_FILE};type=image/png" \
  "$BASE_URL/piece-definitions" 2>&1) || true

rm -f "$PNG_FILE"

PIECEDEF_STATUS=$(echo "$PIECEDEF_RESPONSE" | tail -1)
PIECEDEF_BODY=$(echo "$PIECEDEF_RESPONSE" | sed '$d')
assert_status "$PIECEDEF_STATUS" "201" "Create piece definition"

PIECEDEF_ID=$(json_field "$PIECEDEF_BODY" "id")
IMAGE_URL=$(json_field "$PIECEDEF_BODY" "image_url")
THUMBNAIL_URL=$(json_field "$PIECEDEF_BODY" "thumbnail_url")
pass "Piece Definition ID: $PIECEDEF_ID"

if [[ -n "$IMAGE_URL" ]]; then
  pass "image_url is set: $IMAGE_URL"
else
  fail "image_url is empty"
fi

if [[ -n "$THUMBNAIL_URL" ]]; then
  pass "thumbnail_url is set: $THUMBNAIL_URL"
else
  fail "thumbnail_url is empty"
fi

# ── 5. Verify image served via file proxy ────────────────────
step "5. Verify image via file proxy"

if [[ -n "$IMAGE_URL" ]]; then
  # IMAGE_URL is a path like /v1/files/piece-definitions/uuid/original.png
  PROXY_BASE="http://localhost:${BACKEND_PORT}"
  IMG_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${PROXY_BASE}${IMAGE_URL}" 2>&1)
  assert_status "$IMG_STATUS" "200" "GET original image"

  THUMB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${PROXY_BASE}${THUMBNAIL_URL}" 2>&1)
  assert_status "$THUMB_STATUS" "200" "GET thumbnail image"
else
  fail "Skipped — no image URL"
fi

# ── 6. Create order ─────────────────────────────────────────
step "6. Create order under project"

ORDER_RESPONSE=$(auth_post "$BASE_URL/projects/$PROJECT_ID/orders" \
  '{"title":"Flow Test Order – lot 1"}')

ORDER_STATUS=$(echo "$ORDER_RESPONSE" | tail -1)
ORDER_BODY=$(echo "$ORDER_RESPONSE" | sed '$d')
assert_status "$ORDER_STATUS" "201" "Create order"

ORDER_ID=$(json_field "$ORDER_BODY" "id")
pass "Order ID: $ORDER_ID"

# ── 7. Create piece ─────────────────────────────────────────
step "7. Create piece in order"

PIECE_RESPONSE=$(auth_post "$BASE_URL/orders/$ORDER_ID/pieces" \
  "{\"title\":\"Side Panel\",\"definition_id\":\"$PIECEDEF_ID\",\"dimensions\":{\"Length\":150.5,\"Width\":80.0},\"quantity\":10}")

PIECE_STATUS=$(echo "$PIECE_RESPONSE" | tail -1)
PIECE_BODY=$(echo "$PIECE_RESPONSE" | sed '$d')
assert_status "$PIECE_STATUS" "201" "Create piece"

PIECE_ID=$(json_field "$PIECE_BODY" "id")
pass "Piece ID: $PIECE_ID"

# ── 8. Verify everything is retrievable ──────────────────────
step "8. Verify resources are retrievable"

GET_CLIENT=$(auth_get "$BASE_URL/clients/$CLIENT_ID")
assert_status "$(echo "$GET_CLIENT" | tail -1)" "200" "GET client"

GET_PROJECT=$(auth_get "$BASE_URL/projects/$PROJECT_ID")
assert_status "$(echo "$GET_PROJECT" | tail -1)" "200" "GET project"

GET_ORDER=$(auth_get "$BASE_URL/orders/$ORDER_ID")
assert_status "$(echo "$GET_ORDER" | tail -1)" "200" "GET order"

GET_PIECE=$(auth_get "$BASE_URL/orders/$ORDER_ID/pieces/$PIECE_ID")
assert_status "$(echo "$GET_PIECE" | tail -1)" "200" "GET piece"

GET_PIECEDEF=$(auth_get "$BASE_URL/piece-definitions/$PIECEDEF_ID")
assert_status "$(echo "$GET_PIECEDEF" | tail -1)" "200" "GET piece definition"

# ── 9. Cleanup ───────────────────────────────────────────────
step "9. Cleanup — delete created resources"

DEL_PIECE=$(auth_del "$BASE_URL/orders/$ORDER_ID/pieces/$PIECE_ID")
assert_status "$(echo "$DEL_PIECE" | tail -1)" "204" "DELETE piece"

DEL_ORDER=$(auth_del "$BASE_URL/orders/$ORDER_ID")
assert_status "$(echo "$DEL_ORDER" | tail -1)" "204" "DELETE order"

DEL_PIECEDEF=$(auth_del "$BASE_URL/piece-definitions/$PIECEDEF_ID")
assert_status "$(echo "$DEL_PIECEDEF" | tail -1)" "204" "DELETE piece definition"

DEL_PROJECT=$(auth_del "$BASE_URL/projects/$PROJECT_ID")
assert_status "$(echo "$DEL_PROJECT" | tail -1)" "204" "DELETE project"

DEL_CLIENT=$(auth_del "$BASE_URL/clients/$CLIENT_ID")
assert_status "$(echo "$DEL_CLIENT" | tail -1)" "204" "DELETE client"

# Verify image is gone after piece def deletion
if [[ -n "$IMAGE_URL" ]]; then
  PROXY_BASE="http://localhost:${BACKEND_PORT}"
  GONE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${PROXY_BASE}${IMAGE_URL}" 2>&1)
  assert_status "$GONE_STATUS" "404" "Image cleaned up after delete"
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}=== Full flow test passed (0 failures) ===${NC}"
  echo ""
  exit 0
else
  echo -e "${RED}=== ${FAILURES} step(s) failed ===${NC}"
  echo ""
  exit 1
fi
