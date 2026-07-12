#!/usr/bin/env bash
#
# Weekly off-site push via restic. Backs up:
#   - /var/backups/pg/         — nightly pg_dump output
#   - docker volume miniodata  — via a read-only bind-mount snapshot
#
# Requires:
#   - restic installed on the VPS host (apt install restic)
#   - a configured restic repo (Backblaze B2 is the canonical choice;
#     any S3-compatible store works). Secrets come from the env.
#
# Env (typically /etc/default/restic, chmod 600):
#   RESTIC_REPOSITORY=b2:__project__-backups:/prod
#   RESTIC_PASSWORD=<long-random-string>     # repo encryption key
#   B2_ACCOUNT_ID=<keyID>
#   B2_ACCOUNT_KEY=<applicationKey>
#
# Install (one-time):
#   sudo install -m 0755 /srv/__project__/backups/restic-push.sh /usr/local/bin/
#   sudo restic -r "$RESTIC_REPOSITORY" init
#   echo '30 3 * * 0 deploy /usr/local/bin/restic-push.sh >> /var/log/restic-push.log 2>&1' \
#     | sudo tee /etc/cron.d/restic-push

set -euo pipefail

# shellcheck disable=SC1091
[ -f /etc/default/restic ] && . /etc/default/restic

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set}"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/pg}"
MINIO_VOLUME="${MINIO_VOLUME:-/var/lib/docker/volumes/__project___miniodata/_data}"

echo "[$(date -Is)] restic backup — pg dumps + minio volume"

restic backup \
  --tag weekly \
  --host "$(hostname)" \
  "$BACKUP_DIR" \
  "$MINIO_VOLUME"

echo "[$(date -Is)] pruning old snapshots (keep last 4 weekly, 3 monthly)"
restic forget --prune \
  --keep-weekly 4 \
  --keep-monthly 3

echo "[$(date -Is)] restic push complete"
