#!/usr/bin/env bash
# =============================================================================
# 45_upgrade_guard.sh (G4) — block unacknowledged MAJOR version jumps.
#
# Compares the image's ERPNext major and the live MariaDB version against the
# last-applied versions persisted on the volume. A major jump requires explicit
# acknowledgment via UPGRADE_ERPNEXT_VERSION / UPGRADE_DB_VERSION. Otherwise it
# takes a safety backup and hard-stops with instructions. Minor/patch changes
# pass through. First boot just records the current versions.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "G4: Upgrade-version guard"

CUR_ERP_MAJOR="$(detect_erpnext_major || true)"
CUR_DB_VERSION="$(detect_mariadb_version || true)"
log "Detected: erpnext major=${CUR_ERP_MAJOR:-unknown}, mariadb=${CUR_DB_VERSION:-unknown}"

if [ ! -f "$STATE_FILE" ]; then
  log "No prior upgrade state — recording current versions (first run)."
  state_write "${CUR_ERP_MAJOR:-}" "${CUR_DB_VERSION:-}"
  exit 0
fi

LAST_ERP_MAJOR="$(state_get erpnext_major || true)"
LAST_DB_VERSION="$(state_get mariadb_version || true)"
log "Last applied: erpnext major=${LAST_ERP_MAJOR:-unknown}, mariadb=${LAST_DB_VERSION:-unknown}"

halt_for_upgrade() {
  # $1 = human message describing required acknowledgment
  err "$1"
  warn "Taking a safety backup before stopping ..."
  if ! do_backup; then
    err "Safety backup also failed — fix storage/DB connectivity first."
  fi
  die "Upgrade not acknowledged. Set the required UPGRADE_* variable and redeploy."
}

# --- ERPNext major guard -----------------------------------------------------
if [ -n "$CUR_ERP_MAJOR" ] && [ -n "$LAST_ERP_MAJOR" ] && [ "$CUR_ERP_MAJOR" != "$LAST_ERP_MAJOR" ]; then
  if [ "$CUR_ERP_MAJOR" -gt "$LAST_ERP_MAJOR" ]; then
    if [ "${UPGRADE_ERPNEXT_VERSION:-}" != "$CUR_ERP_MAJOR" ]; then
      halt_for_upgrade "MAJOR ERPNext upgrade detected: ${LAST_ERP_MAJOR} -> ${CUR_ERP_MAJOR}. To proceed set UPGRADE_ERPNEXT_VERSION=${CUR_ERP_MAJOR}."
    fi
    log "Major ERPNext upgrade acknowledged (UPGRADE_ERPNEXT_VERSION=${CUR_ERP_MAJOR})."
  else
    die "Detected a DOWNGRADE of ERPNext (${LAST_ERP_MAJOR} -> ${CUR_ERP_MAJOR}). Downgrades are not supported."
  fi
fi

# --- MariaDB major guard -----------------------------------------------------
if [ -n "$CUR_DB_VERSION" ] && [ -n "$LAST_DB_VERSION" ]; then
  cur_db_major="$(major_of "$CUR_DB_VERSION")"
  last_db_major="$(major_of "$LAST_DB_VERSION")"
  if [ "$cur_db_major" != "$last_db_major" ]; then
    if [ "${UPGRADE_DB_VERSION:-}" != "$CUR_DB_VERSION" ]; then
      halt_for_upgrade "MAJOR MariaDB change detected: ${LAST_DB_VERSION} -> ${CUR_DB_VERSION}. To proceed set UPGRADE_DB_VERSION=${CUR_DB_VERSION}."
    fi
    log "MariaDB version change acknowledged (UPGRADE_DB_VERSION=${CUR_DB_VERSION})."
  fi
fi

log "Upgrade guard passed."
