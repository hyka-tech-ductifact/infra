#!/usr/bin/env bash
# restore.sh — Restore a PostgreSQL backup.
#
# Usage:
#   ./scripts/restore.sh <environment> [backup_file]
#
#   environment:  local | staging | prod
#   backup_file:  path to .sql.gz file (optional — defaults to the latest backup)
#
# WARNING: This will DROP and recreate the database. All current data will be lost.
#
# Examples:
#   ./scripts/restore.sh staging                                    # restore latest
#   ./scripts/restore.sh staging /var/backups/ductifact/staging/20260412_030000.sql.gz

set -euo pipefail

# ── Arguments ────────────────────────────────────────────────
ENV="${1:-}"
BACKUP_FILE="${2:-}"

if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <environment> [backup_file]"
  echo "  environment: local | staging | prod"
  exit 1
fi

case "$ENV" in
  local|staging|prod) ;;
  *)
    echo "ERROR: unknown environment '$ENV'. Use 'local', 'staging', or 'prod'."
    exit 1
    ;;
esac

# ── Load environment variables ───────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${INFRA_DIR}/.env.${ENV}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE"
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# ── Resolve backup file ─────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-${HOME}/backups/ductifact}/${ENV}"

if [[ -z "$BACKUP_FILE" ]]; then
  # Find the latest backup
  BACKUP_FILE="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  if [[ -z "$BACKUP_FILE" ]]; then
    echo "ERROR: no backups found in $BACKUP_DIR"
    exit 1
  fi
  echo "No backup file specified, using latest: $BACKUP_FILE"
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "ERROR: backup file not found: $BACKUP_FILE"
  exit 1
fi

# ── Safety confirmation ──────────────────────────────────────
BACKUP_SIZE="$(du -h "$BACKUP_FILE" | cut -f1)"
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  WARNING: This will DROP and recreate the database.     ║"
echo "║  All current data in '$ENV' will be lost.               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Environment:  $ENV"
echo "  Database:     $DB_NAME"
echo "  Backup file:  $BACKUP_FILE ($BACKUP_SIZE)"
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Verify container is running ──────────────────────────────
CONTAINER="ductifact_${ENV}_postgres"

if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "ERROR: container '$CONTAINER' is not running."
  exit 1
fi

# ── Stop the app to prevent connections during restore ───────
APP_CONTAINER="ductifact_${ENV}_app"
APP_WAS_RUNNING=false

if docker inspect --format='{{.State.Running}}' "$APP_CONTAINER" 2>/dev/null | grep -q true; then
  echo "Stopping app container to prevent active connections..."
  docker stop "$APP_CONTAINER" >/dev/null
  APP_WAS_RUNNING=true
fi

# ── Restore ──────────────────────────────────────────────────
echo "Dropping and recreating database '$DB_NAME'..."

docker exec "$CONTAINER" \
  psql -U "${DB_USER}" -d postgres \
  -c "DROP DATABASE IF EXISTS ${DB_NAME};" \
  -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

echo "Restoring from backup..."

gunzip -c "$BACKUP_FILE" \
  | docker exec -i "$CONTAINER" \
    pg_restore -U "${DB_USER}" -d "${DB_NAME}" --no-owner --no-acl

echo "Restore complete."

# ── Restart app if it was running ────────────────────────────
if [[ "$APP_WAS_RUNNING" == true ]]; then
  echo "Restarting app container..."
  docker start "$APP_CONTAINER" >/dev/null
  echo "App restarted. Migrations will run automatically on startup."
fi

echo "Done."
