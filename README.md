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
3. [Adding Apps](#adding-apps)
   - [Add a Local Custom App](#add-a-local-custom-app)
   - [Add an External Frappe App](#add-an-external-frappe-app)
4. [Deploying to Railway](#deploying-to-railway)
5. [Environment Variables](#environment-variables)
6. [Upgrading (detailed guide)](#upgrading)
   - [Concepts & Version Matrix](#concepts--version-matrix)
   - [Pre-flight Checklist](#pre-flight-checklist)
   - [Routine/Minor Changes](#routineminor-changes)
   - [Major Base Bump (v15 → v16)](#major-base-bump-v15--v16)
   - [Staging Dry-Run](#staging-dry-run)
   - [Manual Backup & Restore](#manual-backup--restore)
   - [Rollback Procedure](#rollback-procedure)
   - [Troubleshooting](#troubleshooting)
7. [Safety Guards Reference](#safety-guards-reference)
8. [Build Cache Note](#build-cache-note)

---

## Quick Start (Local Dev)

```bash
# 1. Clone and enter the repo
git clone <your-fork-url> frappe-erpnext-starter && cd frappe-erpnext-starter

# 2. Copy environment defaults
cp .env.example .env

# 3. Start the stack (MariaDB 10.6, Redis, ERPNext)
docker compose up --build

# 4. Open http://127.0.0.1:8000 and complete the ERPNext setup wizard

# 5. Restart the container to install any declared custom/external apps
#    (they are gated until setup_complete=1)
docker compose restart erpnext
```

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

## Adding Apps

### Add a Local Custom App

1. Declare it in `deploy/user-apps.json`:
   ```json
   { "custom": [ { "name": "my_app" } ] }
   ```

2. **Option A (Dev auto-scaffold)** — restart the dev container:
   ```bash
   docker compose restart erpnext
   ```
   The entrypoint runs `bench new-app my_app --no-git`, moves it into the bind-mounted
   `apps/`, symlinks it, and installs it to the site.

3. **Option B (Explicit/manual)** — exec in and scaffold:
   ```bash
   docker compose exec erpnext bash
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
docker compose restart erpnext
```

**Production** — external apps must be baked into the image. Rebuild so `bench get-app`
runs at build time:

```bash
docker compose up --build
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

6. **Deploy**. First boot creates the site and starts web-only (wizard not done).

7. **Complete the setup wizard** in your browser.

8. **Restart** the deployment — custom/external apps install and the full stack starts.

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
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

1. **ERPNext base image** (`FROM frappe/erpnext:v15.x.y`)
2. **External app branches** (`"branch": "version-15"` in `user-apps.json`)
3. **MariaDB** (10.6 for v15)

| ERPNext Image | External Branch | MariaDB |
|---------------|-----------------|---------|
| v15.x | `version-15` | 10.6 |
| v16.x | `version-16` | 10.6+ (verify release notes) |

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

1. Edit `user-apps.json` (external branch) or the base image tag in `Dockerfile`
2. Commit and push/redeploy
3. The container boots, takes a backup, auto-migrates, and starts
4. Verify in logs: `Migration succeeded`

### Major Base Bump (v15 → v16)

**NEVER skip majors** (v14→v16). Do sequential upgrades only.

#### Step-by-step

1. **Bump the Dockerfile base image**:
   ```dockerfile
   FROM frappe/erpnext:v16.81.0
   ```

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
   UPGRADE_DB_VERSION=10.6   # or new version if MariaDB also changed
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
   - Revert `Dockerfile` to the previous base image tag
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
If you ever see "stale external app" behavior, add `--no-cache` to your build:

```bash
docker compose build --no-cache
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