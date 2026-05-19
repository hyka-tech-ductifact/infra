#!/usr/bin/env bash
# db.sh — Manage PostgreSQL backups (create, restore, list).
#
# Usage:
#   ./scripts/db.sh <command> <environment> [backup_file]
#
# Commands:
#   backup   <env>                 Create a compressed backup
#   restore  <env> [backup_file]   Restore a backup (latest if omitted)
#   list     <env>                 List available backups
#
# Environments: local | staging | prod
#
# Examples:
#   ./scripts/db.sh backup  prod
#   ./scripts/db.sh restore staging
#   ./scripts/db.sh restore staging ~/backups/ductifact/staging/20260412_030000.sql.gz
#   ./scripts/db.sh list    prod
#
# Cron setup (daily at 3:00 AM):
# crontab -e (to edit)
# crontab -l (to list)
#   0 3 * * * cd ~/ductifact/infra && ./scripts/db.sh backup prod >> ~/backups/ductifact/backup.log 2>&1

set -euo pipefail

RETENTION_DAYS=7

# ── Helpers ──────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <command> <environment> [backup_file]"
  echo ""
  echo "Commands:"
  echo "  backup   <env>                Create a compressed backup"
  echo "  restore  <env> [backup_file]  Restore a backup (latest if omitted)"
  echo "  list     <env>                List available backups"
  echo ""
  echo "Environments: local | staging | prod"
  exit 1
}

validate_env() {
  case "$1" in
    local|staging|prod) ;;
    *)
      echo "ERROR: unknown environment '$1'. Use 'local', 'staging', or 'prod'."
      exit 1
      ;;
  esac
}

load_env() {
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  INFRA_DIR="$(dirname "$SCRIPT_DIR")"
  ENV_FILE="${INFRA_DIR}/.env.${ENV}"

  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: $ENV_FILE"
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$ENV_FILE"

  CONTAINER="ductifact_${ENV}_postgres"
  BACKUP_DIR="${BACKUP_DIR:-${HOME}/backups/ductifact}/${ENV}"
}

require_container() {
  if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: container '$CONTAINER' is not running."
    exit 1
  fi
}

# ── Commands ─────────────────────────────────────────────────
cmd_backup() {
  load_env
  require_container

  # Create backup directory
  if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
    echo "ERROR: cannot create backup directory '$BACKUP_DIR'."
    echo "  Fix permissions:  sudo mkdir -p \"$(dirname "$BACKUP_DIR")\" && sudo chown \"$(whoami)\" \"$(dirname "$BACKUP_DIR")\""
    echo "  Or set BACKUP_DIR in $ENV_FILE to a writable path."
    exit 1
  fi

  TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
  BACKUP_FILE="${BACKUP_DIR}/${TIMESTAMP}.sql.gz"

  echo "Creating backup: $BACKUP_FILE"

  docker exec "$CONTAINER" \
    pg_dump -U "${DB_USER}" --format=custom "${DB_NAME}" \
    | gzip > "$BACKUP_FILE"

  # Verify the file is not empty
  if [[ ! -s "$BACKUP_FILE" ]]; then
    echo "ERROR: backup file is empty, something went wrong."
    rm -f "$BACKUP_FILE"
    exit 1
  fi

  BACKUP_SIZE="$(du -h "$BACKUP_FILE" | cut -f1)"
  echo "Backup complete: $BACKUP_FILE ($BACKUP_SIZE)"

  # Clean old backups
  DELETED=$(find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete -print | wc -l)
  if [[ "$DELETED" -gt 0 ]]; then
    echo "Cleaned $DELETED backup(s) older than $RETENTION_DAYS days."
  fi
}

cmd_restore() {
  local FILE="${1:-}"
  load_env

  # Resolve backup file
  if [[ -z "$FILE" ]]; then
    FILE="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    if [[ -z "$FILE" ]]; then
      echo "ERROR: no backups found in $BACKUP_DIR"
      exit 1
    fi
    echo "No backup file specified, using latest: $FILE"
  fi

  if [[ ! -f "$FILE" ]]; then
    echo "ERROR: backup file not found: $FILE"
    exit 1
  fi

  # Safety confirmation
  BACKUP_SIZE="$(du -h "$FILE" | cut -f1)"
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  WARNING: This will DROP and recreate the database.     ║"
  echo "║  All current data in '$ENV' will be lost.               ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Environment:  $ENV"
  echo "  Database:     $DB_NAME"
  echo "  Backup file:  $FILE ($BACKUP_SIZE)"
  echo ""
  read -rp "Type 'yes' to confirm: " CONFIRM

  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi

  require_container

  # Stop the backend to prevent connections during restore
  BACKEND_CONTAINER="ductifact_${ENV}_backend"
  BACKEND_WAS_RUNNING=false

  if docker inspect --format='{{.State.Running}}' "$BACKEND_CONTAINER" 2>/dev/null | grep -q true; then
    echo "Stopping backend container to prevent active connections..."
    docker stop "$BACKEND_CONTAINER" >/dev/null
    BACKEND_WAS_RUNNING=true
  fi

  # Restore
  echo "Dropping and recreating database '$DB_NAME'..."

  docker exec "$CONTAINER" \
    psql -U "${DB_USER}" -d postgres \
    -c "DROP DATABASE IF EXISTS ${DB_NAME};" \
    -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

  echo "Restoring from backup..."

  gunzip -c "$FILE" \
    | docker exec -i "$CONTAINER" \
      pg_restore -U "${DB_USER}" -d "${DB_NAME}" --no-owner --no-acl

  echo "Restore complete."

  # Restart backend if it was running
  if [[ "$BACKEND_WAS_RUNNING" == true ]]; then
    echo "Restarting backend container..."
    docker start "$BACKEND_CONTAINER" >/dev/null
    echo "Backend restarted. Migrations will run automatically on startup."
  fi
}

cmd_list() {
  load_env

  echo "Backups for '$ENV' in $BACKUP_DIR:"
  echo ""

  if ! ls "$BACKUP_DIR"/*.sql.gz &>/dev/null; then
    echo "  (none)"
    return
  fi

  # Show backups sorted by date (newest first) with size
  find "$BACKUP_DIR" -maxdepth 1 -name '*.sql.gz' -printf '%T@ %p\n' \
    | sort -rn \
    | while read -r _ file; do
        SIZE="$(du -h "$file" | cut -f1)"
        DATE="$(date -r "$file" '+%Y-%m-%d %H:%M:%S')"
        echo "  $DATE  $SIZE  $(basename "$file")"
      done

  COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name '*.sql.gz' | wc -l)
  echo ""
  echo "Total: $COUNT backup(s)"
}

# ── Main ─────────────────────────────────────────────────────
COMMAND="${1:-}"
ENV="${2:-}"

if [[ -z "$COMMAND" ]] || [[ -z "$ENV" ]]; then
  usage
fi

validate_env "$ENV"

case "$COMMAND" in
  backup)
    cmd_backup
    ;;
  restore)
    cmd_restore "${3:-}"
    ;;
  list)
    cmd_list
    ;;
  *)
    echo "ERROR: unknown command '$COMMAND'."
    echo ""
    usage
    ;;
esac

echo "Done."
