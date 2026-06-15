#!/usr/bin/env bash
# =============================================================================
# 30_erpnext.sh — ensure the ERPNext app is installed on the site.
# Must complete BEFORE any custom/external app (they depend on erpnext).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "Ensuring ERPNext is installed"

if app_installed_on_site erpnext; then
  log "ERPNext already installed on '${SITE_NAME}'."
else
  log "Installing ERPNext on '${SITE_NAME}' ..."
  bench --site "$SITE_NAME" install-app erpnext
  log "ERPNext installed."
fi
