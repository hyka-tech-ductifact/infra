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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

ENVIRONMENT="${1:-}"
case "$ENVIRONMENT" in
    staging|production) ;;
    *)
        echo "Usage: $0 <staging|production>"
        exit 1
        ;;
esac

for key in VPS_SSH_KEY CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET VPS_USER VPS_HOST; do
    if [[ -z "${!key:-}" ]]; then
        echo "ERROR: required environment variable '$key' is not set"
        exit 1
    fi
done

ENV_FILE_NAME=".env.${ENVIRONMENT}"
ENV_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$ENV_TMP_DIR"' EXIT
ENV_TMP_FILE="${ENV_TMP_DIR}/${ENV_FILE_NAME}"

# Shared with local generation; resolves CI secrets and validates before SSH.
"${SCRIPT_DIR}/generate_env.sh" "$ENVIRONMENT" --output "$ENV_TMP_FILE"

if ! command -v cloudflared > /dev/null 2>&1; then
	echo "Installing cloudflared..."
	curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
		-o /tmp/cloudflared.deb
	sudo dpkg -i /tmp/cloudflared.deb
fi

mkdir -p ~/.ssh
printf '%s\n' "$VPS_SSH_KEY" > ~/.ssh/deploy_key
chmod 600 ~/.ssh/deploy_key

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
