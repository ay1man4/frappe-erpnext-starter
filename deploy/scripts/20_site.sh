#!/usr/bin/env bash
# =============================================================================
# 20_site.sh — create the site (idempotent) or reconcile its DB connection.
#
# Uses a fixed DB_NAME so the site reconnects to the same managed database
# across redeploys. The MariaDB root password is used only at creation time and
# is never persisted in site_config.json.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Guard SITE_NAME before using it in any path operation.
if [ -z "$SITE_NAME" ] || [[ "$SITE_NAME" =~ [^a-zA-Z0-9_.-] ]]; then
  die "Invalid SITE_NAME: '$SITE_NAME'"
fi

section "Site setup: ${SITE_NAME}"

if site_exists; then
  log "Site already exists — reconciling DB connection from environment."
  bench --site "$SITE_NAME" set-config db_host "$DB_HOST"
  bench --site "$SITE_NAME" set-config db_port "$DB_PORT"
  bench --site "$SITE_NAME" set-config db_name "$DB_NAME"
  # Ensure a stale root password from older deploys is not retained.
  CFG="$(site_config_path)"
  if jq -e 'has("db_root_password")' "$CFG" >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq 'del(.db_root_password)' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
    log "Removed persisted db_root_password from site config."
  fi
  log "Site DB connection reconciled."
else
  log "Creating site '${SITE_NAME}' with fixed db-name '${DB_NAME}' ..."
  bench new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --db-host "$DB_HOST" \
    --db-port "$DB_PORT" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --mariadb-user-host-login-scope='%' \
    --no-mariadb-socket \
    --force

  # Pin the encryption key BEFORE relying on stored secrets. Because new-site
  # already encrypted the admin password with a generated key, re-set the admin
  # password afterwards so it is re-encrypted with the pinned key.
  if [ -n "${ENCRYPTION_KEY:-}" ]; then
    log "Pinning ENCRYPTION_KEY and re-encrypting admin password ..."
    bench --site "$SITE_NAME" set-config encryption_key "$ENCRYPTION_KEY"
    bench --site "$SITE_NAME" set-admin-password "$ADMIN_PASSWORD"
  fi

  log "Site created: ${SITE_NAME}"
fi

# Make this the default site for bench/gunicorn.
bench use "$SITE_NAME"
bench set-config -g default_site "$SITE_NAME"

# Assets are copied from the image seed by 05_volume_guard.sh on every startup.
# bench build is kept as a last-resort fallback only.
ASSETS_JSON="$BENCH_DIR/sites/assets/assets.json"
if [ ! -f "$ASSETS_JSON" ]; then
  log "assets.json missing — running bench build as fallback ..."
  cd "$BENCH_DIR" && bench build --hard-link
  log "Assets built."
else
  log "Assets present (from image seed)."
fi

# Frappe caches assets.json in Redis. With shared=True the key is stored bare
# ('assets_json'); other code paths may store it db-name-prefixed
# ('<db_name>|assets_json'). bench clear-cache only clears site-scoped keys and
# will NOT evict the shared entry. Delete every known form unconditionally so
# the next request always reloads the current manifest from disk.
# redis-cli is not installed in the image — use redis-py from the frappe venv.
_redis_url="${REDIS_CACHE_URL:-redis://redis:6379}"
_flushed="$("$BENCH_DIR/env/bin/python3" - "$_redis_url" "${DB_NAME:-}" <<'PY'
import sys, redis
url, dbname = sys.argv[1], sys.argv[2]
r = redis.from_url(url)
keys = ["assets_json", "assets_rtl_json"]
if dbname:
    keys += [f"{dbname}|assets_json", f"{dbname}|assets_rtl_json"]
print(r.delete(*keys))
PY
)"
log "Flushed Redis assets_json cache (${_flushed:-0} key(s) removed)."
