# =============================================================================
# ERPNext base-image template
# The ERPNext major (ERPNEXT_VERSION) MUST match every `external` app branch in
# user-apps.json (e.g. v15 image <-> version-15 apps). See README "Upgrading".
#
# ERPNEXT_VERSION is a REQUIRED build arg with no default — supplied from
# deploy/release.env locally (via compose) and as a Railway build variable in
# production. The guard stage below stops the build with a clear message if it
# is missing, so an image is never built against an unintended base.
# =============================================================================
ARG ERPNEXT_VERSION

# ---- Guard stage: fail fast with a readable message if ERPNEXT_VERSION is unset.
FROM busybox:1.36 AS version-guard
ARG ERPNEXT_VERSION
RUN test -n "$ERPNEXT_VERSION" \
      || { echo "ERROR: ERPNEXT_VERSION build arg is required (set deploy/release.env or a Railway build variable)."; exit 1; }; \
    printf '%s' "$ERPNEXT_VERSION" > /version-guard-ok

# ---- Main stage. The :-MISSING sentinel keeps the image reference syntactically
# valid when the arg is empty, so the guard's clear error surfaces instead of an
# opaque 'invalid reference format'. The COPY --from at the end of this stage
# forces the guard to pass before the image is assembled.
FROM frappe/erpnext:${ERPNEXT_VERSION:-MISSING}
ARG ERPNEXT_VERSION

USER root
WORKDIR /home/frappe/frappe-bench

# Force a build dependency on the guard stage: the marker file only exists when
# the guard passed, so a missing ERPNEXT_VERSION fails the build here too.
COPY --from=version-guard /version-guard-ok /tmp/.version-guard-ok

# Tooling: gosu (drop root -> frappe in entrypoint) + jq (parse user-apps.json).
RUN apt-get update \
    && apt-get install -y --no-install-recommends gosu jq \
    && rm -rf /var/lib/apt/lists/*

# Process manager + entrypoint phase scripts.
COPY --chown=frappe:frappe ./deploy/config/Procfile ./Procfile
COPY --chown=frappe:frappe ./deploy/config/nginx.conf ./nginx.conf
COPY --chown=frappe:frappe --chmod=0755 ./deploy/scripts /opt/erpnext-scripts
# App manifest. Baked at a stable path the entrypoint reads (UA_FILE); in local
# dev the host ./deploy is bind-mounted over /opt/deploy for live editing.
COPY --chown=frappe:frappe ./deploy/user-apps.json /opt/deploy/user-apps.json

# -----------------------------------------------------------------------------
# External Frappe apps (build time). Baked from the manifest so production images
# are immutable; a manifest content change invalidates this layer and re-fetches.
# (Local dev fetches newly-declared external apps at runtime — see 40_user_apps.sh.)
# -----------------------------------------------------------------------------
USER frappe

RUN set -eu; \
    UA=/opt/deploy/user-apps.json; \
    if [ -s "$UA" ]; then \
      count="$(jq '.external | length' "$UA")"; \
      i=0; \
      while [ "$i" -lt "$count" ]; do \
        url="$(jq -r ".external[$i].url // empty" "$UA")"; \
        branch="$(jq -r ".external[$i].branch // empty" "$UA")"; \
        if [ -n "$url" ]; then \
          if [ -n "$branch" ]; then \
            echo "==> get-app $url (branch $branch)"; \
            bench get-app --branch "$branch" "$url"; \
          else \
            echo "==> get-app $url"; \
            bench get-app "$url"; \
          fi; \
        fi; \
        i=$((i + 1)); \
      done; \
    fi

# -----------------------------------------------------------------------------
# Local custom apps (build time). Copy committed source (repo ./apps) into an
# image staging dir, then editable-install each Python app. Empty apps/ = no-op.
# -----------------------------------------------------------------------------
COPY --chown=frappe:frappe ./apps ./apps-src

RUN set -eu; \
    for app in apps-src/*/; do \
      [ -d "$app" ] || continue; \
      name="$(basename "$app")"; \
      if [ -f "$app/pyproject.toml" ] || [ -f "$app/setup.py" ]; then \
        echo "==> Installing custom app: $name"; \
        rm -rf "apps/$name"; \
        cp -a "$app" "apps/$name"; \
        bench pip install -e "apps/$name"; \
        if ! grep -qxF "$name" sites/apps.txt 2>/dev/null; then \
          [ -s sites/apps.txt ] && [ -n "$(tail -c1 sites/apps.txt)" ] && printf '\n' >> sites/apps.txt; \
          echo "$name" >> sites/apps.txt; \
        fi; \
      fi; \
    done

# Compile JS/CSS assets for all apps baked into the image.
RUN bench build

# Default local port (Railway injects a dynamic $PORT and ignores EXPOSE).
EXPOSE 8000

# Entrypoint runs as ROOT so it can chown the mounted volume, then drops to the
# `frappe` user (via gosu) for all bench operations.
USER root

# Keep a seed copy of sites/ so the entrypoint can re-seed when an empty
# persistent volume shadows the image. Contains apps.txt (from the base image +
# custom-app appends above) and assets/. common_site_config is created at runtime
# by bench set-config (10_redis.sh / 20_site.sh). The app manifest lives outside
# the volume at /opt/deploy/user-apps.json.
RUN cp -a /home/frappe/frappe-bench/sites /opt/sites-seed

ENTRYPOINT ["bash", "/opt/erpnext-scripts/entrypoint.sh"]
