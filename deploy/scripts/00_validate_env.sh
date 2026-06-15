#!/usr/bin/env bash
# =============================================================================
# 00_validate_env.sh (G1) — fail fast if required environment is missing.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "G1: Validating environment"

REQUIRED=(
  SITE_NAME
  ADMIN_PASSWORD
  DB_HOST
  DB_PORT
  DB_NAME
  DB_ROOT_PASSWORD
  REDIS_CACHE_URL
  REDIS_QUEUE_URL
  REDIS_SOCKETIO_URL
)

missing=()
for var in "${REQUIRED[@]}"; do
  if [ -z "${!var:-}" ]; then
    missing+=("$var")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  err "The following required environment variables are not set:"
  for var in "${missing[@]}"; do
    err "  - $var"
  done
  die "Set the missing variables (see .env.example) and restart."
fi

if ! is_dev && [ -z "${ENCRYPTION_KEY:-}" ]; then
  warn "ENCRYPTION_KEY is not set in a non-dev environment."
  warn "Pin it (see README) so stored passwords survive a config regeneration."
fi

log "All required environment variables are present."
