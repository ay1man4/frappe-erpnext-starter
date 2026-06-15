#!/usr/bin/env python3
"""Offload the most recent ERPNext backup set to S3-compatible storage.

Reads configuration from environment variables (all optional except the three
credentials/bucket):

    BACKUP_S3_BUCKET       (required)
    BACKUP_S3_ACCESS_KEY   (required)
    BACKUP_S3_SECRET_KEY   (required)
    BACKUP_S3_ENDPOINT     (optional, e.g. https://s3.amazonaws.com)
    BACKUP_S3_REGION       (optional, default us-east-1)
    SITE_NAME              (used as the object key prefix)

Usage: s3_offload.py <backups_dir>

Uploads the newest *-database.sql.gz, *-files.tar, *-private-files.tar and
*-site_config_backup.json. Exits non-zero on any failure so the caller can
report that the offload did not succeed.
"""
import glob
import os
import sys


def newest(pattern):
    matches = glob.glob(pattern)
    if not matches:
        return None
    return max(matches, key=os.path.getmtime)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: s3_offload.py <backups_dir>\n")
        return 2

    backups_dir = sys.argv[1]
    bucket = os.environ.get("BACKUP_S3_BUCKET")
    access_key = os.environ.get("BACKUP_S3_ACCESS_KEY")
    secret_key = os.environ.get("BACKUP_S3_SECRET_KEY")
    endpoint = os.environ.get("BACKUP_S3_ENDPOINT") or None
    region = os.environ.get("BACKUP_S3_REGION") or "us-east-1"
    site = os.environ.get("SITE_NAME", "site")

    if not (bucket and access_key and secret_key):
        sys.stderr.write("S3 offload: missing bucket/access/secret env vars.\n")
        return 2

    try:
        import boto3  # provided by the frappe python environment
    except ImportError:
        sys.stderr.write("S3 offload: boto3 not available in this environment.\n")
        return 3

    patterns = [
        "*-database.sql.gz",
        "*-files.tar",
        "*-private-files.tar",
        "*-site_config_backup.json",
    ]
    files = []
    for pat in patterns:
        f = newest(os.path.join(backups_dir, pat))
        if f:
            files.append(f)

    if not files:
        sys.stderr.write("S3 offload: no backup files found to upload.\n")
        return 4

    client = boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=region,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    # Group uploads under a per-site, per-backup-timestamp prefix when possible.
    base = os.path.basename(files[0])
    stamp = base.split("-database")[0] if "-database" in base else "backup"
    prefix = "{}/{}".format(site, stamp)

    failed = False
    for path in files:
        key = "{}/{}".format(prefix, os.path.basename(path))
        try:
            client.upload_file(path, bucket, key)
            sys.stdout.write("uploaded s3://{}/{}\n".format(bucket, key))
        except Exception as exc:  # noqa: BLE001 - report and continue
            sys.stderr.write("S3 offload failed for {}: {}\n".format(path, exc))
            failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
