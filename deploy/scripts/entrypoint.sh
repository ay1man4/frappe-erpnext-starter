#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh — orchestrates the gated, idempotent startup flow.
#
# Runs first as ROOT (validate env, guard + prepare the persistent volume),
# then re-execs itself as the `frappe` user via gosu for all bench operations.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# -----------------------------------------------------------------------------
# ROOT phase: only the tasks that require root, then drop privileges.
# -----------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  section "Starting ERPNext container for site: ${SITE_NAME:-<unset>}"
  bash "$SCRIPT_DIR/00_validate_env.sh"   # G1 — env & secret validation
  bash "$SCRIPT_DIR/05_volume_guard.sh"   # G2 — volume mount / seed / chown
  log "Dropping privileges to 'frappe' user ..."
  exec gosu frappe bash "$0" "$@"
fi

# -----------------------------------------------------------------------------
# FRAPPE phase: everything else.
# -----------------------------------------------------------------------------
bash "$SCRIPT_DIR/10_redis.sh"             # configure redis (global)
wait_for_db
bash "$SCRIPT_DIR/15_encryption_guard.sh"  # G3 — encryption-key consistency
bash "$SCRIPT_DIR/20_site.sh"              # create or reconcile the site
bash "$SCRIPT_DIR/30_erpnext.sh"           # install erpnext if missing

if setup_complete; then
  log "Setup wizard complete — running full provisioning."
  bash "$SCRIPT_DIR/40_user_apps.sh"       # scaffold/install custom + external apps
  bash "$SCRIPT_DIR/45_upgrade_guard.sh"   # G4 — version acknowledgment guard
  bash "$SCRIPT_DIR/48_backup.sh"          # G5 — pre-migrate backup (integrity)
  bash "$SCRIPT_DIR/50_migrate.sh"         # G6 — migrate (maintenance/lock/halt)
  export FULL_STACK=1
else
  warn "Setup wizard NOT complete — starting WEB-ONLY so you can finish setup."
  warn "Open the site in a browser, complete the wizard, then restart the container."
  export FULL_STACK=0
fi

exec bash "$SCRIPT_DIR/60_start.sh"
