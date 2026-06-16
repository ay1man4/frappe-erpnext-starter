---
description: Cut a release / update version pins and git tags
---

Use this to bump a pinned version and update release branches + git tags.
All version pins live in a single file: `deploy/release.env` (the only file that
differs between `main` and `release/vN`). It is protected by a `merge=ours` git
driver so `main` merges never clobber a branch's pins.

## One-time setup (per clone)

Enable the merge driver (git does not commit this config):
// turbo
1. `git config merge.ours.driver true`

## Bump a version pin

2. Decide the target branch:
   - Newest major changes land on `main` and the matching `release/vN`.
   - Older majors are maintained only on their `release/vN` branch.
3. Edit `deploy/release.env` and set the new values, e.g.:
   ```
   ERPNEXT_VERSION=v15.112.0
   MARIADB_VERSION=10.6
   ```
4. If a major changed, also bump each `external[].branch` in `deploy/user-apps.json`
   to the matching major (verify the app actually publishes that branch).
5. Validate the pins resolve and Compose renders:
// turbo
6. `./erpnext config >/dev/null && echo OK`  (or `docker compose --env-file .env --env-file deploy/release.env config`)
7. Commit on the chosen branch:
   ```
   git add deploy/release.env deploy/user-apps.json
   git commit -m "chore(release): pin ERPNext ${ERPNEXT_VERSION}"
   ```

## Propagate to release branches (conflict-free)

8. Merge `main` into the relevant release branch (release.env stays pinned via merge=ours):
   ```
   git checkout release/v15 && git merge main && git checkout -
   ```

## Tag

9. Create the immutable, annotated release tag:
   ```
   git tag -a v15.112.0 -m "ERPNext v15.112.0 pin" && git push origin v15.112.0
   ```
10. Move the "latest" pointers (lightweight, force-updated):
    ```
    git tag -f v15-latest release/v15 && git push -f origin v15-latest
    # Only if this is the newest supported major overall:
    git tag -f latest release/v15 && git push -f origin latest
    ```

## Railway note

11. Railway builds the `Dockerfile` directly and cannot read `release.env`. For each
    Railway service set/update the **build variable** `ERPNEXT_VERSION` to match the
    branch's pin, then redeploy. A missing value stops the build at the guard stage.
