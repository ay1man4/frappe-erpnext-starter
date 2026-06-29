#!/usr/bin/env bash
# =============================================================================
# 40_user_apps.sh — provision the apps declared in user-apps.json.
#
# Custom apps (.custom[].name):
#   - dev/local: auto-scaffold any declared-but-missing app, persisting the
#     source into the bind-mounted apps staging dir, then symlink into
#     frappe-bench/apps and editable-install.
#   - prod: code is baked into the image; a declared-but-missing app is a hard
#     error (never scaffold into ephemeral storage).
# External apps (.external[].url):
#   - dev/local: git-fetched at runtime if not already baked, then installed.
#   - prod: must be baked into the image at build; a missing one is a hard error.
# Finally, install every custom + external app onto the site (idempotent).
# Only runs once the setup wizard is complete (gated by entrypoint.sh).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "Provisioning user apps (custom + external)"

# Where the host ./apps folder is bind-mounted in dev (see compose).
STAGING_DIR="${CUSTOM_APPS_STAGING:-/home/frappe/custom_apps}"

# Apps that failed to provision (dev only — collected and reported, never fatal).
APP_FAILURES=""

# fail_or_warn <app> <message>: PROD hard-stops (a broken deploy must not serve);
# DEV warns, records the app, and CONTINUES so the site still starts and stays
# reachable for debugging. One bad app never blocks the whole stack in dev.
fail_or_warn() {
  local name="$1" msg="$2"
  if is_dev; then
    warn "$msg"
    warn "Continuing (dev) so the site still starts — fix '$name' and restart."
    APP_FAILURES="${APP_FAILURES} ${name}"
    return 0
  fi
  die "$msg"
}

ensure_custom_app_present() {
  local name="$1"
  local app_path="$BENCH_DIR/apps/$name"

  if [ -d "$app_path" ]; then
    if is_dev && [ ! -L "$app_path" ] && [ -d "$STAGING_DIR/$name" ]; then
      log "Custom app '$name' is a baked directory — replacing with symlink to staging (dev)."
      rm -rf "$app_path"
      ln -sfn "$STAGING_DIR/$name" "$app_path"
      bench pip install -e "$app_path" || warn "pip install of '$name' failed; continuing."
    else
      log "Custom app '$name' present in bench."
    fi
    return 0
  fi

  if is_dev; then
    mkdir -p "$STAGING_DIR"
    if [ ! -d "$STAGING_DIR/$name" ]; then
      log "Scaffolding new custom app '$name' (dev) ..."
      # bench new-app is interactive with required fields. Feed values from
      # user-apps.json, falling back to sensible defaults for blank/omitted
      # ones. Prompt order: Title[default] -> Description -> Publisher ->
      # Email -> License[mit] -> Create GitHub Workflow [y/N].
      local title desc publisher email license
      title="$(ua_custom_field "$name" title)"
      desc="$(ua_custom_field "$name" description)";  [ -n "$desc" ]      || desc="$name app"
      publisher="$(ua_custom_field "$name" publisher)"; [ -n "$publisher" ] || publisher="Custom"
      email="$(ua_custom_field "$name" email)";       [ -n "$email" ]     || email="admin@example.com"
      license="$(ua_custom_field "$name" license)";   [ -n "$license" ]   || license="mit"
      if ! printf '%s\n%s\n%s\n%s\n%s\nn\n' \
        "$title" "$desc" "$publisher" "$email" "$license" \
        | bench new-app "$name" --no-git; then
        fail_or_warn "$name" "Scaffolding custom app '$name' FAILED."
        return 0
      fi
      # new-app creates it under apps/; relocate into the persistent staging dir.
      if [ -d "$BENCH_DIR/apps/$name" ] && [ ! -L "$BENCH_DIR/apps/$name" ]; then
        mv "$BENCH_DIR/apps/$name" "$STAGING_DIR/$name"
      fi
    fi
    log "Symlinking '$name' from staging into bench apps."
    ln -sfn "$STAGING_DIR/$name" "$app_path"
    if ! bench pip install -e "$app_path"; then
      fail_or_warn "$name" "pip install of custom app '$name' FAILED."
      return 0
    fi
  else
    err "Custom app '$name' is declared in user-apps.json but not present in the image."
    die "Add its source under apps/$name and rebuild before deploying."
  fi
}

install_app_on_site() {
  local name="$1"
  if app_installed_on_site "$name"; then
    log "App '$name' already installed on site."
    return 0
  fi
  log "Installing app '$name' on site ..."
  if bench --site "$SITE_NAME" install-app "$name"; then
    log "App '$name' installed on site."
  else
    fail_or_warn "$name" "Install of app '$name' on the site FAILED."
  fi
}

# --- Custom apps -------------------------------------------------------------
while IFS= read -r name; do
  [ -n "$name" ] || continue
  ensure_custom_app_present "$name"
done < <(ua_custom_names)

# --- Install everything declared onto the site -------------------------------
while IFS= read -r name; do
  [ -n "$name" ] || continue
  install_app_on_site "$name"
done < <(ua_custom_names)

count="$(ua_external_count)"
i=0
while [ "$i" -lt "$count" ]; do
  url="$(ua_external_url "$i")"
  if [ -n "$url" ]; then
    app="$(app_name_from_url "$url")"
    if [ ! -d "$BENCH_DIR/apps/$app" ]; then
      if is_dev; then
        # Dev convenience: fetch a newly-declared external app at runtime so
        # "edit user-apps.json + restart" works without a rebuild. The app lands
        # in the ephemeral bench apps/ (re-fetched on a full container recreate).
        branch="$(ua_external_branch "$i")"
        log "External app '$app' not baked — fetching at runtime (dev) ..."
        fetch_ok=1
        if [ -n "$branch" ]; then
          bench get-app --branch "$branch" "$url" || fetch_ok=0
        else
          bench get-app "$url" || fetch_ok=0
        fi
        if [ "$fetch_ok" = "0" ]; then
          fail_or_warn "$app" "Fetching external app '$app' ($url) FAILED."
          i=$((i + 1)); continue
        fi
        log "Building assets for '$app' ..."
        bench build --app "$app" || warn "Asset build for '$app' failed; continuing."
      else
        err "External app '$app' ($url) is declared but not baked into the image."
        die "Rebuild the image after editing user-apps.json so external apps are fetched."
      fi
    fi
    install_app_on_site "$app"
  fi
  i=$((i + 1))
done

if [ -n "${APP_FAILURES// /}" ]; then
  warn "Some apps failed to provision (dev):${APP_FAILURES}"
  warn "The site is still starting so you can fix them and restart."
fi
log "User apps provisioned."
