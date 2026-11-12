#!/usr/bin/env bash
# Generate an environment, upload it, and trigger deployment.
# Runs on: GitHub Actions runner with CI secrets and SSH access.
# Called by: Staging/production deployment workflows.
# Calls: ops/generate_env.sh; ops/deploy.sh on the server over SSH.
# Usage: ./scripts/ci/deploy_remote.sh <staging|production>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
"${SCRIPT_DIR}/../ops/generate_env.sh" "$ENVIRONMENT" --output "$ENV_TMP_FILE"

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
		"cd ~/ductifact/infra && git pull --ff-only origin main && ./scripts/ops/deploy.sh ${ENVIRONMENT}"
