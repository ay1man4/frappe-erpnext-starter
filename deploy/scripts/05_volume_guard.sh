#!/usr/bin/env bash
# =============================================================================
# 05_volume_guard.sh (G2) — ensure the sites/ persistent volume is mounted,
# seeded, writable, and owned by frappe. Runs as ROOT.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "G2: Volume / persistence guard"

SITES_DIR="$BENCH_DIR/sites"
mkdir -p "$SITES_DIR"

# On Railway, a missing volume mount means data is written to ephemeral storage
# and lost on every redeploy. Detect and hard-stop.
if [ -n "${RAILWAY_ENVIRONMENT:-}" ] && [ -z "${RAILWAY_VOLUME_MOUNT_PATH:-}" ]; then
  die "Running on Railway but no Volume is attached. Mount a Volume at ${SITES_DIR} to persist data."
fi

# Seed-if-empty: an empty mounted volume shadows the image's baked sites/.
# Restore the baked seed (apps.txt, assets, ...) when missing. The app manifest
# is NOT here — it lives outside the volume at /opt/deploy/user-apps.json.
if [ ! -f "$SITES_DIR/apps.txt" ] && [ -d "$SEED_DIR" ]; then
  log "sites/ looks empty — seeding from baked image contents."
  # Copy all entries (including hidden) while skipping the special dirs . and ..
  for item in "$SEED_DIR"/* "$SEED_DIR"/.[!.]* "$SEED_DIR"/..?*; do
    [ -e "$item" ] || continue
    cp -a "$item" "$SITES_DIR/" 2>/dev/null || true
  done
  # Generate sites.txt from actual site directories (exclude assets, locale, etc.)
  ( cd "$SITES_DIR" && ls -d */ 2>/dev/null | sed 's|/$||' | grep -vE '^(assets|locale)$' > sites.txt ) || true
fi

# Refresh sites/assets/ from the image seed on every startup via a CLEAN
# REPLACE (remove, then copy) rather than a merge. Everything under
# sites/assets/ is image-derived (the hashed-bundle manifest assets.json plus
# the app public symlinks) and never holds user data, so wiping it is safe.
#
# A merge (`cp -a seed/assets/. sites/assets/`) onto an existing volume can
# leave a STALE assets.json — and GNU cp can choke copying the seed's app
# symlinks over the previous image's symlinks-to-directories. Either way Frappe
# then emits the OLD hashed /assets URLs, which 404 because the new image only
# ships the new hashes. A clean replace guarantees the manifest and symlinks
# always match the running image.
if [ -d "$SEED_DIR/assets" ]; then
  log "Refreshing sites/assets/ from image seed (clean replace) ..."
  mkdir -p "$SITES_DIR/assets"
  # Clear the CONTENTS of assets/ (not the directory inode itself — on a
  # bind-mounted dev volume / some prod volume backends, unlinking the dir
  # returns EBUSY). Copying into an emptied tree avoids merging onto the
  # previous image's app symlinks and guarantees the manifest is current.
  find "$SITES_DIR/assets" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -a "$SEED_DIR/assets/." "$SITES_DIR/assets/"
  _seed_hash="$(python3 -c "import json; d=json.load(open('$SITES_DIR/assets/assets.json')); print(list(d.values())[0])" 2>/dev/null || echo unknown)"
  log "Assets ready (hash sample: $_seed_hash)."
else
  warn "No assets found in image seed ($SEED_DIR/assets); sites/assets/ left untouched — CSS/JS may be stale."
fi

# Writability check.
if ! ( touch "$VOLUME_MARKER" 2>/dev/null ); then
  die "sites/ volume is not writable at ${SITES_DIR}. Check the volume mount and permissions."
fi
date -u +%Y-%m-%dT%H:%M:%SZ > "$VOLUME_MARKER" 2>/dev/null || true

# Railway mounts volumes as root; bench runs as frappe (uid 1000).
# Only chown files that are actually wrong — a full recursive chown on a
# large sites volume with thousands of uploaded files can take minutes.
log "Fixing ownership of ${SITES_DIR} (frappe:frappe) ..."
find "$SITES_DIR" \( -not -user frappe -o -not -group frappe \) -exec chown frappe:frappe {} + 2>/dev/null || true

log "Volume guard passed."
