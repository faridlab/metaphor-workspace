#!/usr/bin/env bash
#
# Nightly Postgres logical backup. Runs on the VPS host (not inside a
# container) via a systemd timer or crontab. Talks to Postgres through
# `docker compose exec`, so the only things it needs on the host are:
#   - docker + compose v2
#   - the compose project present at $COMPOSE_DIR
#
# Output: /var/backups/pg/__project__-<YYYY-mm-dd>-<HHMM>.sql.gz
# Retention: 7 days on the local host; off-site copy handled by
# restic-push.sh on a weekly cadence.
#
# Install (one-time):
#   sudo install -m 0755 /srv/__project__/backups/pg-backup.sh /usr/local/bin/
#   sudo mkdir -p /var/backups/pg
#   sudo chown deploy:deploy /var/backups/pg
#   echo '15 2 * * * deploy /usr/local/bin/pg-backup.sh >> /var/log/pg-backup.log 2>&1' \
#     | sudo tee /etc/cron.d/pg-backup
#
# Test restore (run once before beta):
#   gunzip -c /var/backups/pg/__project__-<ts>.sql.gz \
#     | docker run --rm -i --network __project___backend \
#         -e PGPASSWORD=$POSTGRES_PASSWORD \
#         postgres:16-alpine \
#         psql -h postgres -U $POSTGRES_USER -d __project___restore

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/srv/__project__}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pg}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

cd "$COMPOSE_DIR"
# shellcheck disable=SC1091
set -a; . ./.env.prod; set +a

timestamp=$(date +"%Y-%m-%d-%H%M")
out="$BACKUP_DIR/__project__-${timestamp}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "[$(date -Is)] pg_dump → $out"
docker compose exec -T postgres \
  pg_dump --no-owner --no-acl \
          -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  | gzip -9 > "$out"

# Retention sweep.
find "$BACKUP_DIR" -name '__project__-*.sql.gz' -type f \
  -mtime +"$RETENTION_DAYS" -print -delete

echo "[$(date -Is)] backup complete ($(du -h "$out" | cut -f1))"
