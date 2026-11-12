#!/usr/bin/env bash
# Generate an environment, upload it, and trigger deployment.
# Runs on: GitHub Actions runner with CI secrets and SSH access.
# Called by: Staging/production deployment workflows.
# Calls: ops/generate_env.sh; ops/deploy.sh on the server over SSH.
# Usage: ./scripts/ci/deploy_remote.sh <staging|production>

set -euo pipefail

# ── Validate arguments and CI variables ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$INFRA_DIR"

[[ $# -eq 1 ]] || { echo "Usage: $0 <staging|production>"; exit 1; }
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

# ── Generate the runtime file ────────────────────────────────────────
ENV_FILE_NAME=".env.${ENVIRONMENT}"
umask 077
ENV_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$ENV_TMP_DIR"' EXIT
ENV_TMP_FILE="${ENV_TMP_DIR}/${ENV_FILE_NAME}"

# Shared with local generation; resolves CI secrets and validates before SSH.
"${SCRIPT_DIR}/../ops/generate_env.sh" "$ENVIRONMENT" --output "$ENV_TMP_FILE"

# ── Prepare SSH access ───────────────────────────────────────────────
if ! command -v cloudflared > /dev/null 2>&1; then
	echo "Installing cloudflared..."
	curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
		-o /tmp/cloudflared.deb
	sudo dpkg -i /tmp/cloudflared.deb
fi

# Keep the key private and remove it together with the generated env file.
KEY_FILE="${ENV_TMP_DIR}/deploy_key"
printf '%s\n' "$VPS_SSH_KEY" > "$KEY_FILE"

# ProxyCommand is interpreted by a shell: quote credentials as arguments.
printf -v SSH_PROXY '%q ' cloudflared access ssh --hostname %h \
  --id "$CF_ACCESS_CLIENT_ID" --secret "$CF_ACCESS_CLIENT_SECRET"
SSH_OPTIONS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o "ProxyCommand=${SSH_PROXY}"
  -i "$KEY_FILE"
)
REMOTE_FILE="${ENV_FILE_NAME}.upload.$(basename "$ENV_TMP_DIR")"
TARGET="${VPS_USER}@${VPS_HOST}"

# ── Upload configuration and deploy remotely ─────────────────────────
# Upload separately, then replace the runtime file only after transfer succeeds.
scp "${SSH_OPTIONS[@]}" "$ENV_TMP_FILE" "$TARGET:ductifact/infra/$REMOTE_FILE"
# Environment and temporary filenames are fixed/generated locally.
# shellcheck disable=SC2029
ssh "${SSH_OPTIONS[@]}" "$TARGET" "
  set -e
  cd ~/ductifact/infra
  trap 'rm -f $REMOTE_FILE' EXIT
  git pull --ff-only origin main
  chmod 600 $REMOTE_FILE
  mv -f $REMOTE_FILE $ENV_FILE_NAME
  ./scripts/ops/deploy.sh $ENVIRONMENT
"
