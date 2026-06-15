#!/usr/bin/env bash
# =============================================================================
# 60_start.sh — start the appropriate process set.
#
#   dev                  -> `bench start` (hot reload: web + workers + watch)
#   prod, setup complete -> honcho/Procfile: gunicorn web + workers + schedule
#   prod, setup pending  -> honcho web only (so the setup wizard is reachable)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "Starting ERPNext (site: ${SITE_NAME}, port: $(web_port))"

export PATH="$BENCH_DIR/env/bin:$PATH"
export PORT="${PORT:-$(web_port)}"
export SITES_PATH="$BENCH_DIR/sites"
SOCKETIO_PORT="${SOCKETIO_PORT:-9000}"

bench use "$SITE_NAME" >/dev/null 2>&1 || true

# Substitute the committed nginx template and write the runtime config.
if [ ! -f "$BENCH_DIR/nginx.conf" ]; then
  die "nginx template not found at $BENCH_DIR/nginx.conf"
fi
sed -e "s|{{PORT}}|$PORT|g" -e "s|{{SITES_DIR}}|$BENCH_DIR/sites|g" -e "s|{{SITE_NAME}}|$SITE_NAME|g" \
    -e "s|{{SOCKETIO_PORT}}|$SOCKETIO_PORT|g" \
    "$BENCH_DIR/nginx.conf" > "$BENCH_DIR/nginx-runtime.conf" || die "Failed to generate nginx runtime config"
log "Generated nginx runtime config for port $PORT (socketio $SOCKETIO_PORT)"

HONCHO="$BENCH_DIR/env/bin/honcho"
[ -x "$HONCHO" ] || HONCHO="honcho"

if is_dev; then
  log "Mode: dev — starting hot-reload stack (bench start)."
  exec bench start
fi

if [ "${FULL_STACK:-0}" = "1" ]; then
  log "Mode: production — starting full stack (web + workers + scheduler)."
  exec "$HONCHO" start
else
  log "Mode: production — WEB-ONLY (complete the setup wizard, then restart)."
  exec "$HONCHO" start nginx gunicorn socketio
fi
