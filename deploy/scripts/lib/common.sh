#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers for the ERPNext entrypoint phases.
# Sourced by entrypoint.sh and every NN_*.sh phase script.
# =============================================================================

# Resolve key paths.
# Directory holding this library and sibling helpers (e.g. s3_offload.py).
# Derived from the source location so it works regardless of the mount path.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
# App manifest — baked outside the sites volume at /opt/deploy/user-apps.json
# (host ./deploy is bind-mounted there in local dev for live editing).
UA_FILE="${UA_FILE:-/opt/deploy/user-apps.json}"
STATE_FILE="${STATE_FILE:-$BENCH_DIR/sites/.upgrade-state.json}"
VOLUME_MARKER="${VOLUME_MARKER:-$BENCH_DIR/sites/.volume-marker}"
MIGRATE_LOCK="${MIGRATE_LOCK:-$BENCH_DIR/sites/.migrate.lock}"
SEED_DIR="${SEED_DIR:-/opt/sites-seed}"

# Always operate from the bench root.
cd "$BENCH_DIR" 2>/dev/null || true

# Ensure node (installed via nvm in the base image) is on PATH. `bench build`
# and the realtime server need it, and some subprocess/login-shell contexts
# drop the nvm bin from PATH. Glob-resolve so a node version bump still works.
if ! command -v node >/dev/null 2>&1; then
  _nvm_bin="$(ls -d /home/frappe/.nvm/versions/node/*/bin 2>/dev/null | tail -1 || true)"
  [ -n "${_nvm_bin:-}" ] && export PATH="$_nvm_bin:$PATH"
fi

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
_ts() { date +%H:%M:%S; }
log()  { printf '[%s] %s\n' "$(_ts)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '[%s] ERROR: %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

section() {
  echo "========================================================================"
  log "$*"
  echo "========================================================================"
}

# ----------------------------------------------------------------------------
# Environment helpers
# ----------------------------------------------------------------------------
# is_dev: true when running in dev mode (hot reload + app scaffolding).
is_dev() {
  local env="${PROJECT_ENV:-dev}"
  [ "$env" = "dev" ]
}

web_port() { echo "${PORT:-8000}"; }

# ----------------------------------------------------------------------------
# Site helpers
# ----------------------------------------------------------------------------
site_config_path() { echo "$BENCH_DIR/sites/$SITE_NAME/site_config.json"; }

site_exists() { [ -f "$(site_config_path)" ]; }

# setup_complete: 0 (true) if the ERPNext setup wizard has been completed.
setup_complete() {
  site_exists || return 1
  local out
  out="$(bench --site "$SITE_NAME" mariadb -e \
"SELECT value FROM tabSingles WHERE doctype='System Settings' AND field='setup_complete';" \
    2>/dev/null | tr -d '\r')" || return 1
  echo "$out" | grep -Eq '^[[:space:]]*1[[:space:]]*$'
}

app_installed_on_site() {
  # $1 = app name
  bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -Eq "^$1([[:space:]]|\$)"
}

# ----------------------------------------------------------------------------
# Wait for the database to accept TCP connections.
# ----------------------------------------------------------------------------
wait_for_db() {
  local tries=0 max="${DB_WAIT_MAX:-60}"
  log "Waiting for database at ${DB_HOST}:${DB_PORT} ..."
  until python3 - "$DB_HOST" "$DB_PORT" <<'PY' 2>/dev/null
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(2)
s.connect((host, port))
s.close()
PY
  do
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      die "Database not reachable at ${DB_HOST}:${DB_PORT} after ${max} attempts."
    fi
    sleep 2
  done
  log "Database is reachable."
}

# ----------------------------------------------------------------------------
# user-apps.json parsing
# ----------------------------------------------------------------------------
ua_custom_names() {
  [ -s "$UA_FILE" ] || return 0
  jq -r '.custom[]?.name // empty' "$UA_FILE" 2>/dev/null
}

# ua_custom_field <app-name> <field>: echo a custom app's metadata field
# (title/description/publisher/email/license), or empty if unset.
ua_custom_field() {
  [ -s "$UA_FILE" ] || return 0
  jq -r --arg n "$1" --arg f "$2" \
    '.custom[]? | select(.name==$n) | .[$f] // empty' "$UA_FILE" 2>/dev/null
}

ua_external_count() {
  [ -s "$UA_FILE" ] || { echo 0; return 0; }
  jq '.external | length' "$UA_FILE" 2>/dev/null || echo 0
}

ua_external_url()    { jq -r ".external[$1].url // empty"    "$UA_FILE" 2>/dev/null; }
ua_external_branch() { jq -r ".external[$1].branch // empty" "$UA_FILE" 2>/dev/null; }

# Derive the Frappe app name from a git URL (basename minus .git).
app_name_from_url() {
  basename "$1" | sed -E 's/\.git$//'
}

# ----------------------------------------------------------------------------
# Version detection
# ----------------------------------------------------------------------------
detect_erpnext_major() {
  local f="$BENCH_DIR/apps/erpnext/erpnext/__init__.py"
  [ -f "$f" ] || return 1
  sed -nE "s/^__version__[[:space:]]*=[[:space:]]*['\"]([0-9]+).*/\1/p" "$f" | head -1
}

# Returns MariaDB version as major.minor (e.g. 10.6).
detect_mariadb_version() {
  local out
  out="$(bench --site "$SITE_NAME" mariadb -e "SELECT VERSION();" 2>/dev/null | tr -d '\r')" || return 1
  echo "$out" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

major_of() { echo "${1%%.*}"; }

# ----------------------------------------------------------------------------
# Upgrade state (sites/.upgrade-state.json)
# ----------------------------------------------------------------------------
state_get() {
  # $1 = key
  [ -f "$STATE_FILE" ] || return 1
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null
}

state_write() {
  # $1 = erpnext_major, $2 = mariadb_version
  cat > "$STATE_FILE" <<JSON
{
  "erpnext_major": "$1",
  "mariadb_version": "$2",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  log "Recorded applied versions: erpnext=$1 mariadb=$2"
}

# ----------------------------------------------------------------------------
# Backup helpers (G5)
# ----------------------------------------------------------------------------
s3_configured() {
  [ -n "${BACKUP_S3_BUCKET:-}" ] && [ -n "${BACKUP_S3_ACCESS_KEY:-}" ] && [ -n "${BACKUP_S3_SECRET_KEY:-}" ] && [ -n "${BACKUP_S3_ENDPOINT:-}" ]
}

ensure_disk_space() {
  local min free
  min="${BACKUP_MIN_FREE_MB:-1024}"
  free="$(df -Pm "$BENCH_DIR/sites" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$free" ] && [ "$free" -lt "$min" ]; then
    err "Insufficient disk space: ${free}MB free on sites volume (< ${min}MB required)."
    return 1
  fi
  log "Disk space OK (${free:-unknown}MB free on sites volume)."
}

prune_backups() {
  local keep dir
  keep="${BACKUP_KEEP:-7}"
  dir="$BENCH_DIR/sites/$SITE_NAME/private/backups"
  [ -d "$dir" ] || return 0
  local pattern
  for pattern in '*-database.sql.gz' '*-files.tar' '*-private-files.tar' '*-site_config_backup.json'; do
    # shellcheck disable=SC2012
    while read -r old; do
      rm -f "$old" && log "Pruned old backup: $(basename "$old")"
    done < <(ls -1t "$dir"/$pattern 2>/dev/null | tail -n +"$((keep + 1))")
  done
}

offload_latest_backups() {
  local dir py
  dir="$BENCH_DIR/sites/$SITE_NAME/private/backups"
  py="$BENCH_DIR/env/bin/python"
  [ -x "$py" ] || py="python3"
  "$py" "$LIB_DIR/s3_offload.py" "$dir"
}

# do_backup: DB backup (optionally with files) + disk check, S3 offload, and
# retention. Defaults to database-only — fast and sufficient for the pre-migrate
# safety net, since migrations touch schema/data, not uploaded files. Set
# BACKUP_WITH_FILES=1 to also tar public/private files (slower, more disk).
# Returns non-zero on backup failure.
do_backup() {
  ensure_disk_space || return 1
  local with_files="" what="database-only"
  if [ "${BACKUP_WITH_FILES:-0}" = "1" ]; then
    with_files="--with-files"
    what="database + files"
  fi
  log "Taking backup (${what}) for site '${SITE_NAME}' ..."
  if ! bench --site "$SITE_NAME" backup ${with_files}; then
    err "Backup FAILED."
    return 1
  fi
  log "Backup completed."
  if s3_configured; then
    log "Offloading backup to S3-compatible storage ..."
    if offload_latest_backups; then
      log "S3 offload verified."
    else
      warn "S3 offload failed — backup remains on the volume."
    fi
  fi
  prune_backups
  return 0
}
