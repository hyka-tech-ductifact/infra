#!/usr/bin/env bash
# backup.sh — Create a compressed PostgreSQL backup.
#
# Usage:
#   ./scripts/backup.sh <environment>
#
#   environment: local | staging | prod
#
# Creates a gzip-compressed pg_dump in /var/backups/ductifact/<env>/
# and removes backups older than RETENTION_DAYS.
#
# Cron setup (daily at 3:00 AM):
#   crontab -e
#   0 3 * * * cd /opt/ductifact && ./scripts/backup.sh prod >> /var/log/ductifact-backup.log 2>&1
#
# Restore with:
#   ./scripts/restore.sh <environment> [backup_file]

set -euo pipefail

# ── Arguments ────────────────────────────────────────────────
ENV="${1:-}"
RETENTION_DAYS=7

if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <environment>"
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

# ── Configuration ────────────────────────────────────────────
CONTAINER="ductifact_${ENV}_postgres"
BACKUP_DIR="/var/backups/ductifact/${ENV}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/${TIMESTAMP}.sql.gz"

# ── Create backup directory ──────────────────────────────────
mkdir -p "$BACKUP_DIR"

# ── Verify container is running ──────────────────────────────
if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "ERROR: container '$CONTAINER' is not running."
  exit 1
fi

# ── Run pg_dump ──────────────────────────────────────────────
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

# ── Clean old backups ────────────────────────────────────────
DELETED=$(find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete -print | wc -l)
if [[ "$DELETED" -gt 0 ]]; then
  echo "Cleaned $DELETED backup(s) older than $RETENTION_DAYS days."
fi

echo "Done. Current backups:"
ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null || echo "  (none)"
