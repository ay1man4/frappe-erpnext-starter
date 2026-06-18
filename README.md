# frappe-erpnext-starter

A production-ready, Dockerized ERPNext starter template that runs the same on
Windows, macOS, and Linux, and deploys cleanly to Railway. It ships as a single
container with:

- **Single-container** web + workers + scheduler (Honcho/Procfile)
- **Declarative app management** via `deploy/user-apps.json`:
  - **Local custom apps**: develop in `apps/`, auto-installed (scaffolded in dev)
  - **External Frappe apps** (hrms, healthcare, etc.): git-fetched at runtime in
    local dev, baked at build time for production
- **Safety guards**: env validation, encryption-key consistency, volume mount check,
  backup integrity, migrate safety, and **upgrade version guards**
- **Railway-first**: managed MariaDB + Redis, persistent volume at `sites/`,
  env-driven configuration

---

## Table of Contents

1. [Quick Start (Local Dev)](#quick-start-local-dev)
2. [How It Works](#how-it-works)
3. [Version Pinning & Release Branches](#version-pinning--release-branches)
4. [Adding Apps](#adding-apps)
   - [Add a Local Custom App](#add-a-local-custom-app)
   - [Add an External Frappe App](#add-an-external-frappe-app)
5. [Deploying to Railway](#deploying-to-railway)
6. [Environment Variables](#environment-variables)
7. [Upgrading (detailed guide)](#upgrading)
   - [Concepts & Version Matrix](#concepts--version-matrix)
   - [Pre-flight Checklist](#pre-flight-checklist)
   - [Routine/Minor Changes](#routineminor-changes)
   - [Major Base Bump (v15 → v16)](#major-base-bump-v15--v16)
   - [Staging Dry-Run](#staging-dry-run)
   - [Manual Backup & Restore](#manual-backup--restore)
   - [Rollback Procedure](#rollback-procedure)
   - [Troubleshooting](#troubleshooting)
8. [Safety Guards Reference](#safety-guards-reference)
9. [Build Cache Note](#build-cache-note)

---

## Quick Start (Local Dev)

```bash
# 1. Clone and enter the repo
git clone <your-fork-url> frappe-erpnext-starter && cd frappe-erpnext-starter

# 2. Start the stack (creates .env on first run, builds, and starts)
./erpnext up --build        # Windows cmd/PowerShell:  .\erpnext up --build

# 3. Open http://127.0.0.1:8000 and complete the ERPNext setup wizard

# 4. Restart to install any declared custom/external apps
#    (they are gated until setup_complete=1)
./erpnext restart erpnext   # Windows:  .\erpnext restart erpnext
```

The `erpnext` wrapper (`./erpnext` on macOS/Linux/Git Bash/WSL, `.\erpnext` on Windows
`cmd`/PowerShell) is a thin pass-through to `docker compose` that **automatically
loads both env files** — your `.env` (settings/secrets) and `deploy/release.env`
(the pinned `ERPNEXT_VERSION` and `MARIADB_VERSION`) — so you never type the
`--env-file` flags. It creates `.env` from `.env.example` on first run. Pass any
Compose args through it, e.g. `./erpnext down`, `./erpnext logs -f`, `./erpnext exec erpnext bash`.

> **No wrapper / raw command** (works the same on every OS):
> ```bash
> cp .env.example .env   # first run only
> docker compose --env-file .env --env-file deploy/release.env up --build
> ```
> Both files are required: `--env-file` *replaces* the default `.env`, so passing
> only `deploy/release.env` would blank out your `.env` values (e.g.
> `DB_ROOT_PASSWORD`). Listing both keeps your settings and adds the version pins.
>
> **Versions are required, not defaulted.** If they aren't loaded, Compose (and the
> Docker build guard) fail fast with a clear "required" message — never a silent
> wrong version.

Local extras (phpMyAdmin on :8090, hot-reload custom apps) are in `docker-compose.override.yml`,
merged automatically.

---

## How It Works

### Startup Flow (Gated)

1. **Env validation** (G1) — fail fast if required vars missing
2. **Volume guard** (G2) — seed empty volume, fix ownership
3. **Redis config** — point bench at Cache/Queue/SocketIO services
4. **Encryption guard** (G3) — never silently change `encryption_key`
5. **Site create/reconcile** — idempotent, fixed `DB_NAME`
6. **ERPNext install** — must be on site before any custom app
7. **Setup wizard check**:
   - **Incomplete** → start **web-only** so you can finish setup
   - **Complete** → continue:
8. **User apps** — scaffold missing custom apps (dev), symlink, pip install
9. **Upgrade guard** (G4) — detect major version jumps, require acknowledgment
10. **Backup** (G5) — pre-migrate backup of DB + files (S3 offload if configured)
11. **Migrate** (G6) — with maintenance mode + concurrency lock + halt-on-fail
12. **Start** — `bench start` (local) or Honcho/Procfile (prod)

### App Manifest (`deploy/user-apps.json`)

```json
{
  "custom": [
    { "name": "my_app" }
  ],
  "external": [
    { "url": "https://github.com/frappe/hrms", "branch": "version-15" }
  ]
}
```

- `custom`: your code in `apps/<name>/`; built into the image; auto-scaffolded in dev if missing
- `external`: git-fetched via `bench get-app --branch <branch> <url>` — at **runtime** in
  local dev (no rebuild) and at **build time** (baked) for production

**Golden rule**: `external` branch major must equal the base image major.
Example: `FROM frappe/erpnext:v15.x` ↔ `"branch": "version-15"`.

---

## Version Pinning & Release Branches

All version-pinned defaults live in a single file, `deploy/release.env`:

```bash
ERPNEXT_VERSION=v15.111.0   # required base image tag (build arg)
MARIADB_VERSION=10.6        # local/compose only (Railway uses managed MariaDB)
```

The `Dockerfile` and `docker-compose.yml` read these values; neither hardcodes a
version. **There are no silent defaults** — a missing `ERPNEXT_VERSION` stops the
Docker build (guard stage), and a missing `MARIADB_VERSION`/`ERPNEXT_VERSION`
makes Compose fail fast.

> **External app branches are not pinned here.** Branch naming is not standard
> across Frappe apps — official ERPNext-aligned apps (`frappe`, `erpnext`, `hrms`,
> `payments`, `healthcare`) use `version-15`/`version-16`, but others (e.g.
> `frappe/lms`) ship from `main`/`develop`. Set each app's branch explicitly via
> the per-app `branch` field in `deploy/user-apps.json`.

### Branch Model

- **`main`** tracks the **newest** supported major. Its `release.env` holds the
  newest pins; the `Dockerfile`/compose carry no version diff.
- **`release/v15`, `release/v16`** are long-lived branches whose **only** intended
  difference from `main` is `deploy/release.env` (pinned to that major).

`deploy/release.env` is protected by a `merge=ours` git driver (see `.gitattributes`),
so merging `main` into a release branch **keeps the branch's pins and never conflicts**.

**One-time per clone** — enable the driver (git does not commit this config):

```bash
git config merge.ours.driver true
```

If you skip this, the merge falls back to a normal (possibly conflicting) merge of
`release.env`.

### Cutting a Release / Updating "latest"

Tags are plain git tags. Immutable per-cut tags plus moving "latest" pointers:

```bash
# Immutable release tag (annotated)
git tag -a v15.111.0 -m "ERPNext v15.111.0 pin" && git push origin v15.111.0

# Moving pointers (lightweight, force-updated)
git tag -f v15-latest release/v15 && git push -f origin v15-latest
git tag -f latest <newest-release>  && git push -f origin latest
```

See `.windsurf/workflows/cut-release.md` for the full checklist.

---

## Adding Apps

### Add a Local Custom App

1. Declare it in `deploy/user-apps.json`:
   ```json
   { "custom": [ { "name": "my_app" } ] }
   ```

2. **Option A (Dev auto-scaffold)** — restart the dev container:
   ```bash
   ./erpnext restart erpnext
   ```
   The entrypoint runs `bench new-app my_app --no-git`, moves it into the bind-mounted
   `apps/`, symlinks it, and installs it to the site.

3. **Option B (Explicit/manual)** — exec in and scaffold:
   ```bash
   ./erpnext exec erpnext bash
   bench new-app my_app --no-git
   # Move it from apps/ to /home/frappe/custom_apps/ so it persists to host
   ```

4. Commit the new `apps/my_app/` folder and updated `deploy/user-apps.json`.

5. Rebuild/redeploy so the app is baked into the image for production.

### Add an External Frappe App

Edit `deploy/user-apps.json`:

```json
{
  "external": [
    { "url": "https://github.com/frappe/hrms", "branch": "version-15" },
    { "url": "https://github.com/frappe/healthcare", "branch": "version-15" }
  ]
}
```

**Local dev** — just restart; the entrypoint git-fetches the new external app at runtime
and installs it (no rebuild). It lands in the ephemeral `apps/`, so it re-fetches on a
full container recreate:

```bash
./erpnext restart erpnext
```

**Production** — external apps must be baked into the image. Rebuild so `bench get-app`
runs at build time:

```bash
./erpnext up --build
```

A declared external app that isn't baked is a **hard error** in production (fail-fast with
a "rebuild" message), keeping prod images immutable and fast-booting.

---

## Deploying to Railway

1. **Fork/clone this repo to GitHub.**

2. **Create project on Railway** → add your repo.

3. **Add services**:
   - **MariaDB** (plugin) — creates `DB_HOST`, `DB_PORT`, `DB_ROOT_PASSWORD`
   - **Redis** (three instances: Cache, Queue, SocketIO)
     - Redis Cache → `REDIS_CACHE_URL`
     - Redis Queue → `REDIS_QUEUE_URL`
     - Redis SocketIO → `REDIS_SOCKETIO_URL`

4. **Create a Volume**:
   - Mount path: `/home/frappe/frappe-bench/sites`

5. **Configure environment** (see `.env.example`):
   ```
   PROJECT_ENV=${{RAILWAY_ENVIRONMENT}}
   SITE_NAME=site1.local
   DB_NAME=erpnext_prod
   DB_HOST=${{MariaDB.MARIADB_HOST}}
   DB_PORT=${{MariaDB.MARIADB_PORT}}
   DB_ROOT_PASSWORD=${{MariaDB.MARIADB_ROOT_PASSWORD}}
   REDIS_CACHE_URL=${{Redis Cache.REDIS_URL}}
   REDIS_QUEUE_URL=${{Redis Queue.REDIS_URL}}
   REDIS_SOCKETIO_URL=${{Redis SocketIO.REDIS_URL}}
   ADMIN_PASSWORD=<generate-strong-password>
   ENCRYPTION_KEY=<generate-once-keep-forever>
   ```

   Generate `ENCRYPTION_KEY`:
   ```bash
   python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
   ```

6. **Set the base-image version (REQUIRED).** Railway builds the `Dockerfile`
   directly and cannot read `deploy/release.env`, so add a **build variable**
   matching the value pinned on the branch this service deploys:
   ```
   ERPNEXT_VERSION=v15.111.0
   ```
   If omitted, the build stops at the guard stage with a clear error. (Point the
   v15 service at `release/v15`, the v16 service at `release/v16`, etc.)

7. **Deploy**. First boot creates the site and starts web-only (wizard not done).

8. **Complete the setup wizard** in your browser.

9. **Restart** the deployment — custom/external apps install and the full stack starts.

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ERPNEXT_VERSION` | Yes (build) | Base image tag, from `deploy/release.env`. Required build arg; build fails if missing. On Railway set as a build variable. |
| `MARIADB_VERSION` | Yes (compose) | MariaDB image tag, from `deploy/release.env`. Required by Compose; not used on Railway (managed MariaDB). |
| `PROJECT_ENV` | Yes | `dev` (or unset) for hot reload, anything else for production |
| `SITE_NAME` | Yes | Site identifier (e.g., `site1.local`) |
| `DB_HOST` | Yes | MariaDB host |
| `DB_PORT` | Yes | MariaDB port (usually 3306) |
| `DB_NAME` | Yes | Fixed DB name for the site |
| `DB_ROOT_PASSWORD` | Yes | MariaDB root password |
| `ADMIN_PASSWORD` | Yes | ERPNext admin password |
| `REDIS_CACHE_URL` | Yes | Redis for cache |
| `REDIS_QUEUE_URL` | Yes | Redis for queue |
| `REDIS_SOCKETIO_URL` | Yes | Redis for SocketIO |
| `ENCRYPTION_KEY` | Strongly recommended | Fernet key for encrypting stored passwords |
| `PORT` | No | Web port (default 8000) |
| `SOCKETIO_PORT` | No | Realtime Socket.IO node port; nginx proxies `/socket.io/` here (default 9000) |
| `GUNICORN_WORKERS` | No | Workers for production web (default 2) |
| `BACKUP_S3_*` | Optional | S3 offload credentials (see below) |
| `BACKUP_WITH_FILES` | Optional | `1` to include uploaded files in pre-migrate backups; default DB-only (faster) |
| `UPGRADE_ERPNEXT_VERSION` | On major bump | Acknowledge ERPNext major upgrade |
| `UPGRADE_DB_VERSION` | On major bump | Acknowledge MariaDB version change |
| `AUTO_RESTORE_ON_FAIL` | Optional | Set to `1` to auto-restore backup on failed migrate (default `0`) |

### S3 Backup Offload (Optional)

To push backups to S3-compatible storage:

```
BACKUP_S3_ENDPOINT=https://s3.amazonaws.com
BACKUP_S3_REGION=us-east-1
BACKUP_S3_BUCKET=my-erpnext-backups
BACKUP_S3_ACCESS_KEY=AKIA...
BACKUP_S3_SECRET_KEY=...
BACKUP_KEEP=7
BACKUP_MIN_FREE_MB=1024
```

---

## Upgrading

> **CRITICAL**: Read this entire section before attempting any major upgrade.

### Concepts & Version Matrix

Three version numbers must stay compatible:

1. **ERPNext base image** (`ERPNEXT_VERSION` in `deploy/release.env`)
2. **External app branches** (`"branch": "version-15"` in `user-apps.json`)
3. **MariaDB** (`MARIADB_VERSION` in `deploy/release.env`; 10.6 for v15, 11.8 for v16)

| ERPNext Image | External Branch | MariaDB |
|---------------|-----------------|---------|
| v15.x | `version-15` | 10.6 |
| v16.x | `version-16` | 11.8 |

**Golden rule**: base major == every external branch major.

### Pre-flight Checklist

Before any upgrade:

- [ ] Read the ERPNext and Frappe release notes for breaking changes
- [ ] Confirm your custom apps in `apps/` are compatible with the target version
- [ ] Ensure `ENCRYPTION_KEY` is set (so passwords stay decryptable across config resets)
- [ ] If using S3 backups: verify `BACKUP_*` credentials are valid
- [ ] Confirm disk space on the sites volume (>1 GB free recommended)
- [ ] Note expected downtime (depends on DB size and migration complexity)

### Routine/Minor Changes

Changing a patch version or an external app patch branch is low risk:

1. Edit `deploy/release.env` (`ERPNEXT_VERSION`) and/or `user-apps.json` (external branch)
2. Commit and push/redeploy (on Railway, update the `ERPNEXT_VERSION` build variable too)
3. The container boots, takes a backup, auto-migrates, and starts
4. Verify in logs: `Migration succeeded`

### Major Base Bump (v15 → v16)

**NEVER skip majors** (v14→v16). Do sequential upgrades only.

#### Step-by-step

1. **Bump the base image pin** in `deploy/release.env` (and the Railway
   `ERPNEXT_VERSION` build variable):
   ```bash
   ERPNEXT_VERSION=v16.10.1
   MARIADB_VERSION=11.8   # v16's official stack uses MariaDB 11.8
   ```
   On `release/vN` branches this is the only version edit; the `Dockerfile`
   is unchanged. (Typically you bump on `main`/the matching `release/v16`.)

2. **Bump every `external` branch** together:
   ```json
   { "external": [
     { "url": "https://github.com/frappe/hrms", "branch": "version-16" }
   ]}
   ```

3. **Update `apps/` code** for v16 compatibility (test locally first).

4. **Verify/raise MariaDB** if v16 requires a newer version (check Frappe docs).

5. **Set the upgrade acknowledgment env vars** (so the guard allows the migration):
   ```
   UPGRADE_ERPNEXT_VERSION=16
   UPGRADE_DB_VERSION=11.8   # set to the new MariaDB version when it changes
   ```

6. **Redeploy**. The container will:
   - Run the upgrade guard (detects the jump, sees acknowledgment)
   - Take a pre-migrate backup (to volume + S3 if configured)
   - Enable maintenance mode
   - Run `bench migrate`
   - Record the new applied versions in `sites/.upgrade-state.json`
   - Start the full stack

7. **Verify** the application works, run smoke tests, check background jobs.

### Staging Dry-Run

**Strongly recommended** before touching production data.

1. Create a **throwaway Railway environment** (or local compose stack).
2. Restore a **copy** of production data into it:
   ```bash
   bench --site site1.local restore /path/to/backup.sql.gz --db-root-password ...
   ```
3. Run the upgrade procedure against the copy.
4. Validate thoroughly.
5. If successful, promote the same image/tag to production.

### Manual Backup & Restore

The entrypoint handles pre-migrate backups automatically, but you can run them manually:

```bash
# Inside the container (as frappe user)
bench --site site1.local backup --with-files

# Backups land in sites/site1.local/private/backups/
# Latest set: *-database.sql.gz, *-files.tar, *-private-files.tar, *-site_config_backup.json
```

**Restore** (destructive—use on staging or when rolling back):

```bash
bench --site site1.local restore /path/to/backup-database.sql.gz \
  --db-root-password "$DB_ROOT_PASSWORD" \
  --force
```

### Rollback Procedure

If a migration fails or the upgrade is broken:

1. **Revert the code**:
   - Revert `deploy/release.env` (`ERPNEXT_VERSION`) to the previous base image tag
     (and the Railway `ERPNEXT_VERSION` build variable)
   - Revert `user-apps.json` external branches to previous versions
   - Revert `apps/` code if needed

2. **Redeploy** the reverted image.

3. **Restore the pre-upgrade backup** (taken automatically before the failed migrate):
   ```bash
   # Find the backup taken just before the failed upgrade
   ls -la sites/site1.local/private/backups/
   # Restore it
   bench --site site1.local restore <backup-file> --db-root-password ... --force
   ```

4. **Caveat**: some migrations make **irreversible schema changes**. If you hit this,
   you must fix forward (debug and patch) rather than rollback. This is why the
   **staging dry-run** is critical.

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `BUILD FAILED: ERPNEXT_VERSION is not set` | Build started without the version (e.g. missing Railway build var) | Set `ERPNEXT_VERSION` (from `deploy/release.env`) as a **BUILD** variable in Railway Service > Settings > Variables |
| `ERPNEXT_VERSION is required` / `MARIADB_VERSION is required` (Compose) | Ran `docker compose` without loading the pins | Add `--env-file .env --env-file deploy/release.env` to the command (or `set -a; . deploy/release.env; set +a` on bash) |
| `ERROR: Set UPGRADE_ERPNEXT_VERSION=...` | Major version jump not acknowledged | Set `UPGRADE_ERPNEXT_VERSION=<new-major>` and redeploy |
| `Backup FAILED — aborting` | Disk full or DB unreachable | Free disk; check DB connectivity; retry |
| `Migration FAILED` | Incompatible custom app, or data issue | Check logs; fix custom app; consider `AUTO_RESTORE_ON_FAIL=1` temporarily |
| `sites/ volume is not writable` | Volume not mounted or permission issue | Verify Railway volume mount path; check `chown` in logs |
| `ENCRYPTION_KEY does not match` | Env key differs from persisted site key | Ensure `ENCRYPTION_KEY` matches the site's original key, or unset it to use the persisted one |
| External app missing in image (prod) | `deploy/user-apps.json` external changed but image not rebuilt | Rebuild image so `bench get-app` runs again (dev fetches it at runtime) |

---

## Safety Guards Reference

| Guard | Phase | Behavior |
|-------|-------|----------|
| G0 Build version | build | Stop the Docker build if `ERPNEXT_VERSION` build arg is missing (guard stage); Compose also fails fast if `ERPNEXT_VERSION`/`MARIADB_VERSION` are unset |
| G1 Env validation | 00 | Hard-stop if required env vars missing |
| G2 Volume mount | 05 | Hard-stop if `sites/` is not a writable mount (prevents ephemeral data loss) |
| G3 Encryption consistency | 15 | Never silently change `encryption_key`; hard-stop on mismatch |
| G4 Upgrade version | 45 | Detect major jumps; require `UPGRADE_*` acknowledgment; backup + hard-stop if missing |
| G5 Backup integrity | 48 | Abort migrate if backup fails; S3 offload + retention pruning |
| G6 Migrate safety | 50 | Maintenance mode + concurrency lock; halt on failure |

---

## Build Cache Note

`COPY ./deploy/user-apps.json` appears **before** the `bench get-app` layer in the Dockerfile.
Changing a branch or URL in the manifest invalidates that layer cache, forcing a re-fetch.
If you ever see "stale external app" behavior, build without cache:

```bash
./erpnext build --no-cache
```

---

## License

This template (the Dockerfiles, scripts, configuration, and documentation in
this repository) is licensed under the **MIT License** — see [`LICENSE`](LICENSE).
Use at your own risk. Always test upgrades on copies of production data.

The software it provisions retains its own licensing:

- **ERPNext** — GNU GPL v3
- **Frappe Framework** — MIT

This repository orchestrates and deploys those projects but does not relicense
them. Any custom or external apps you add via `deploy/user-apps.json` remain
subject to their respective licenses.