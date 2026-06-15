#!/usr/bin/env bash
# =============================================================================
# 10_redis.sh — point bench at the Cache / Queue / SocketIO Redis services.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "Configuring Redis + realtime connections"

# common_site_config.json is NOT shipped in the repo seed (all its keys are set
# at runtime). `bench set-config -g` errors if the file is missing, so create an
# empty one on first boot. This is the first frappe-phase bench command to need it.
CSC="$BENCH_DIR/sites/common_site_config.json"
[ -f "$CSC" ] || echo '{}' > "$CSC"

bench set-config -g redis_cache    "$REDIS_CACHE_URL"
bench set-config -g redis_queue    "$REDIS_QUEUE_URL"
bench set-config -g redis_socketio "$REDIS_SOCKETIO_URL"

# Port the Socket.IO (realtime) node server listens on; nginx proxies
# /socket.io/ here. -p parses the value as an int (Frappe expects a number).
bench set-config -gp socketio_port "${SOCKETIO_PORT:-9000}"

log "Redis + realtime configuration applied."
