#!/usr/bin/env bash
# =============================================================================
# 48_backup.sh (G5) — pre-migrate backup with integrity gate.
#
# Never migrate without a good backup: if the backup fails, abort here so the
# migrate phase never runs. Backups go to the volume and (when BACKUP_S3_* is
# set) are offloaded to S3, with local retention pruning.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "G5: Pre-migrate backup"

if ! do_backup; then
  die "Pre-migrate backup failed — aborting before migration to protect your data."
fi

log "Pre-migrate backup complete."
