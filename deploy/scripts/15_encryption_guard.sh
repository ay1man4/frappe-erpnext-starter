#!/usr/bin/env bash
# =============================================================================
# 15_encryption_guard.sh (G3) — protect the site encryption key.
#
# If a site already exists, the env ENCRYPTION_KEY (when provided) MUST match
# the key stored in site_config.json. We NEVER silently regenerate or overwrite
# a working key, because that makes every stored password undecryptable.
# (New-site key pinning happens in 20_site.sh.)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "G3: Encryption-key consistency guard"

if ! site_exists; then
  log "No existing site yet — key will be pinned at creation."
  exit 0
fi

CFG="$(site_config_path)"
STORED_KEY="$(jq -r '.encryption_key // empty' "$CFG" 2>/dev/null || true)"

if [ -n "${ENCRYPTION_KEY:-}" ]; then
  if [ -n "$STORED_KEY" ] && [ "$STORED_KEY" != "$ENCRYPTION_KEY" ]; then
    err "ENCRYPTION_KEY does not match the key stored in the existing site."
    err "Refusing to continue: changing the key makes stored passwords undecryptable."
    die "Either unset ENCRYPTION_KEY to keep the existing key, or restore the correct key."
  fi
  if [ -z "$STORED_KEY" ]; then
    log "Pinning ENCRYPTION_KEY into the existing site config."
    bench --site "$SITE_NAME" set-config encryption_key "$ENCRYPTION_KEY"
  else
    log "Encryption key matches the configured value."
  fi
else
  if [ -n "$STORED_KEY" ]; then
    warn "ENCRYPTION_KEY env is empty; using the key already stored on the volume."
    warn "Set ENCRYPTION_KEY in your environment to survive a volume/config reset."
  else
    warn "No encryption key set anywhere yet; Frappe will manage one on the volume."
  fi
fi

log "Encryption-key guard passed."
