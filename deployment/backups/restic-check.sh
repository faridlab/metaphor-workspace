#!/usr/bin/env bash
#
# Monthly restic repository integrity check. Catches B2-side corruption
# before you actually need to restore.
#
# `--read-data-subset=10%` downloads and verifies a 10 % sample of pack
# data each run — over ~10 months the whole repo gets re-read. Cheaper
# than a full `restic check --read-data` (which downloads everything,
# costs egress on B2) but still detects bit-rot statistically.
#
# Exits non-zero if integrity check fails, so cron will email the
# operator (assuming MAILTO is set in the crontab).
#
# Install (one-time):
#   sudo install -m 0755 /srv/__project__/backups/restic-check.sh /usr/local/bin/
#   echo 'MAILTO=ops@__project__.com'                                            \
#     | sudo tee    /etc/cron.d/restic-check
#   echo '0 4 1 * * deploy /usr/local/bin/restic-check.sh >> /var/log/restic-check.log 2>&1' \
#     | sudo tee -a /etc/cron.d/restic-check

set -euo pipefail

# shellcheck disable=SC1091
[ -f /etc/default/restic ] && . /etc/default/restic

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set}"

echo "[$(date -Is)] restic check --read-data-subset=10%"

restic check --read-data-subset=10%

echo "[$(date -Is)] restic check passed"
