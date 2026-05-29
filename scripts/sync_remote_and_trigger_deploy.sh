#!/usr/bin/env bash
# sync_remote_and_trigger_deploy.sh — Build a runtime env file, copy it to the VPS, and trigger deploy.sh.
#
# Intended to run inside GitHub Actions.
#
# Usage:
#   ./scripts/sync_remote_and_trigger_deploy.sh <environment>
#
#   environment: staging | production

set -euo pipefail

ENVIRONMENT="${1:-}"
SHARED_IMAGES_FILE="environments/images.manifest.env"
ENV_FILE_NAME=""
CONFIG_FILE=""
APP_MANIFEST_FILE=""
ENV_TMP_FILE=""

usage() {
	echo "Usage: $0 <staging|production>"
	exit 1
}

require_env_var() {
	local key="$1"
	if [[ -z "${!key:-}" ]]; then
		echo "ERROR: required environment variable '$key' is not set"
		exit 1
	fi
}

if [[ -z "$ENVIRONMENT" ]]; then
	usage
fi

case "$ENVIRONMENT" in
	staging)
		ENV_FILE_NAME=".env.staging"
		CONFIG_FILE="environments/staging.config.env"
		APP_MANIFEST_FILE="environments/staging.manifest.env"
		;;
	production)
		ENV_FILE_NAME=".env.production"
		CONFIG_FILE="environments/production.config.env"
		APP_MANIFEST_FILE="environments/production.manifest.env"
		;;
	*)
		echo "ERROR: unknown environment '$ENVIRONMENT'. Use 'staging' or 'production'."
		exit 1
		;;
esac

ENV_TMP_FILE="/tmp/${ENV_FILE_NAME}"

for key in \
	VPS_SSH_KEY \
	CF_ACCESS_CLIENT_ID \
	CF_ACCESS_CLIENT_SECRET \
	VPS_USER \
	VPS_HOST \
	DB_PASSWORD \
	JWT_SECRET \
	MINIO_ROOT_USER \
	MINIO_ROOT_PASSWORD \
	SMTP_USERNAME \
	SMTP_PASSWORD \
	REDIS_PASSWORD; do
	require_env_var "$key"
done

for file in "$CONFIG_FILE" "$APP_MANIFEST_FILE" "$SHARED_IMAGES_FILE"; do
	if [[ ! -f "$file" ]]; then
		echo "ERROR: required file '$file' not found"
		exit 1
	fi
done

if ! command -v cloudflared > /dev/null 2>&1; then
	echo "Installing cloudflared..."
	curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
		-o /tmp/cloudflared.deb
	sudo dpkg -i /tmp/cloudflared.deb
fi

mkdir -p ~/.ssh
printf '%s\n' "$VPS_SSH_KEY" > ~/.ssh/deploy_key
chmod 600 ~/.ssh/deploy_key

{
	cat "$CONFIG_FILE"
	printf '\n'
	cat "$APP_MANIFEST_FILE"
	printf '\n'
	cat "$SHARED_IMAGES_FILE"
	printf '\n'
} > "$ENV_TMP_FILE"

sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" "$ENV_TMP_FILE"
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" "$ENV_TMP_FILE"
sed -i "s|^MINIO_ROOT_USER=.*|MINIO_ROOT_USER=${MINIO_ROOT_USER}|" "$ENV_TMP_FILE"
sed -i "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}|" "$ENV_TMP_FILE"
sed -i "s|^SMTP_USERNAME=.*|SMTP_USERNAME=${SMTP_USERNAME}|" "$ENV_TMP_FILE"
sed -i "s|^SMTP_PASSWORD=.*|SMTP_PASSWORD=${SMTP_PASSWORD}|" "$ENV_TMP_FILE"
sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASSWORD}|" "$ENV_TMP_FILE"

INVALID_ENV_LINES=$(grep -nEv '^\s*$|^\s*#|^[A-Za-z_][A-Za-z0-9_]*=.*$' "$ENV_TMP_FILE" || true)
if [[ -n "$INVALID_ENV_LINES" ]]; then
	echo "ERROR: generated ${ENV_FILE_NAME} has invalid lines:"
	echo "$INVALID_ENV_LINES"
	exit 1
fi

chmod 600 "$ENV_TMP_FILE"

SSH_PROXY="cloudflared access ssh --hostname %h --id ${CF_ACCESS_CLIENT_ID} --secret ${CF_ACCESS_CLIENT_SECRET}"
TARGET_PATH="ductifact/infra/${ENV_FILE_NAME}"

scp -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o "ProxyCommand=${SSH_PROXY}" \
		-i ~/.ssh/deploy_key \
		"$ENV_TMP_FILE" \
		"${VPS_USER}@${VPS_HOST}:${TARGET_PATH}"

ssh -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o "ProxyCommand=${SSH_PROXY}" \
		-i ~/.ssh/deploy_key \
		"${VPS_USER}@${VPS_HOST}" \
		"cd ~/ductifact/infra && git pull --ff-only origin main && ./scripts/deploy.sh ${ENVIRONMENT}"

rm -f "$ENV_TMP_FILE"
