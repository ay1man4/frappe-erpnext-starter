#!/usr/bin/env bash
# =============================================================================
# 50_migrate.sh (G6) — run bench migrate safely.
#
# - Concurrency lock (flock) so overlapping redeploys can't migrate at once.
# - Maintenance mode on during migration.
# - Halt (don't serve) on failure; optionally auto-restore the pre-migrate
#   backup when AUTO_RESTORE_ON_FAIL=1.
# - On success, record the applied versions in the upgrade-state file.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "G6: Database migration"

# Acquire an exclusive, non-blocking lock for the duration of this phase.
exec 9>"$MIGRATE_LOCK"
if ! flock -n 9; then
  die "Another migration is already in progress (lock held). Aborting."
fi

cleanup() {
  bench --site "$SITE_NAME" set-maintenance-mode off >/dev/null 2>&1 || true
}

restore_latest_backup() {
  local dir db
  dir="$BENCH_DIR/sites/$SITE_NAME/private/backups"
  db="$(ls -1t "$dir"/*-database.sql.gz 2>/dev/null | head -1 || true)"
  if [ -z "$db" ]; then
    err "No database backup found to restore."
    return 1
  fi
  warn "Auto-restoring latest backup: $(basename "$db")"
  bench --site "$SITE_NAME" restore "$db" \
    --db-root-password "$DB_ROOT_PASSWORD" \
    --force
}

log "Enabling maintenance mode ..."
bench --site "$SITE_NAME" set-maintenance-mode on >/dev/null 2>&1 || true

log "Running bench migrate ..."
if bench --site "$SITE_NAME" migrate; then
  cleanup
  log "Migration succeeded."
  state_write "$(detect_erpnext_major || true)" "$(detect_mariadb_version || true)"
else
  err "Migration FAILED."
  if [ "${AUTO_RESTORE_ON_FAIL:-0}" = "1" ]; then
    restore_latest_backup || err "Auto-restore failed — manual recovery required."
  fi
  cleanup
  die "Halting: not serving a half-migrated site. Review logs, restore the pre-migrate backup if needed, and see README 'Upgrading'."
fi
