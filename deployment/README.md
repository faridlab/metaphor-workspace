# __PROJECT__ Beta — Operator Runbook

Matches the plan in [../docs/DEPLOYMENT-PLAN.md](../docs/DEPLOYMENT-PLAN.md). Read the plan first for architecture; this file is the short, ordered list of commands an operator runs on the VPS.

> **Looking for local dev?** This runbook is for the prod/uat VPS stack ([compose.yaml](compose.yaml)). Local development uses [compose.dev.yaml](compose.dev.yaml) — see [../docs/LOCAL-DEVELOPMENT.md](../docs/LOCAL-DEVELOPMENT.md).

## Layout on the VPS

The VPS mirrors the workspace's `deployment/` and `apps/` layout side-by-side
under one project root, so compose `env_file:` paths resolve identically in
both contexts.

```
/srv/__project__/                                 # project root on VPS
├── deployment/                                # mirrors workspace deployment/
│   ├── compose.yaml
│   ├── .env.prod                              # orchestration config (chmod 600)
│   ├── caddy/Caddyfile
│   ├── prometheus/prometheus.yml
│   ├── loki/loki-config.yaml
│   ├── promtail/promtail-config.yaml
│   ├── grafana/provisioning/
│   └── backups/
│       ├── pg-backup.sh
│       └── restic-push.sh
└── apps/                                      # mirrors workspace apps/ (env files only)
    └── __project__-service/
        └── .env.prod                          # service-owned runtime (chmod 600)
```

> **Two-file env model, single ownership.** `deployment/.env.prod` holds
> orchestration (image tags, infra creds, edge config) — owned by the
> deployment workspace. `apps/__project__-service/.env.prod` holds runtime
> config the service binary needs (JWT secret, MinIO access creds, log
> level) — owned by the service repo, with the contract committed at
> `apps/__project__-service/.env.prod.example`. Compose loads both via
> stacked `env_file:` entries; the path `../apps/__project__-service/.env.prod`
> resolves identically locally and on the VPS because the workspace
> structure is mirrored. Run compose from `/srv/__project__/deployment/`
> on the VPS (not `/srv/__project__/`).

## First deploy

```bash
# On the laptop — build + push the five images.
# Vite bakes VITE_API_BASE_URL into the bundle at build time, so the URL
# must be passed explicitly — a bundle built for staging cannot be moved
# to production without a rebuild.
SHA=$(git rev-parse --short HEAD)
DOMAIN=__project__.com   # or the real beta domain

docker buildx build --platform linux/amd64 \
  -t ghcr.io/faridlab/__project__-service:$SHA \
  -t ghcr.io/faridlab/__project__-service:beta \
  --push apps/__project__-service

docker buildx build --platform linux/amd64 \
  --build-arg VITE_API_BASE_URL=https://api.${DOMAIN} \
  -t ghcr.io/faridlab/__project__-webapp-customer:$SHA \
  -t ghcr.io/faridlab/__project__-webapp-customer:beta \
  --push apps/__project__-webapp-customer

docker buildx build --platform linux/amd64 \
  --build-arg VITE_API_BASE_URL=https://api.${DOMAIN} \
  -t ghcr.io/faridlab/__project__-webapp-provider:$SHA \
  -t ghcr.io/faridlab/__project__-webapp-provider:beta \
  --push apps/__project__-webapp-provider

docker buildx build --platform linux/amd64 \
  --build-arg VITE_API_BASE_URL=https://api.${DOMAIN} \
  -t ghcr.io/faridlab/__project__-webapp-admin:$SHA \
  -t ghcr.io/faridlab/__project__-webapp-admin:beta \
  --push apps/__project__-webapp-admin

docker buildx build --platform linux/amd64 \
  --build-arg VITE_API_BASE_URL=https://api.${DOMAIN} \
  -t ghcr.io/faridlab/__project__-webapp-download:$SHA \
  -t ghcr.io/faridlab/__project__-webapp-download:beta \
  --push apps/__project__-webapp-download

# On the laptop — prepare both env files and validate locally first.
cd path/to/__project__-metaphor

cp deployment/.env.prod.example deployment/.env.prod
chmod 600 deployment/.env.prod
$EDITOR deployment/.env.prod                                  # fill DOMAIN / POSTGRES_* / MINIO_ROOT_* / SMTP_* / etc.
sed -i "s/^SERVICE_TAG=.*/SERVICE_TAG=$SHA/"                 deployment/.env.prod
sed -i "s/^WEBAPP_CUSTOMER_TAG=.*/WEBAPP_CUSTOMER_TAG=$SHA/" deployment/.env.prod
sed -i "s/^WEBAPP_PROVIDER_TAG=.*/WEBAPP_PROVIDER_TAG=$SHA/" deployment/.env.prod
sed -i "s/^WEBAPP_ADMIN_TAG=.*/WEBAPP_ADMIN_TAG=$SHA/"       deployment/.env.prod
sed -i "s/^WEBAPP_DOWNLOAD_TAG=.*/WEBAPP_DOWNLOAD_TAG=$SHA/" deployment/.env.prod

cp apps/__project__-service/.env.prod.example apps/__project__-service/.env.prod
chmod 600 apps/__project__-service/.env.prod
$EDITOR apps/__project__-service/.env.prod                       # fill JWT_SECRET / MINIO_ACCESS_KEY / MINIO_SECRET_KEY

./scripts/preflight-prod.sh                                   # validates BOTH files

# On the VPS — first deploy.
ssh deploy@vps "mkdir -p /srv/__project__/deployment /srv/__project__/apps/__project__-service"

# Sync deployment/ tree (rsync — only changed bytes, supports --dry-run for preview).
# Add --dry-run before the real run to see exactly what would change.
rsync -avz --delete \
  --exclude='.env.prod.example' --exclude='.gitignore' \
  deployment/ deploy@vps:/srv/__project__/deployment/

rsync -avz \
  apps/__project__-service/.env.prod \
  deploy@vps:/srv/__project__/apps/__project__-service/.env.prod

ssh deploy@vps
cd /srv/__project__/deployment

# Login to GHCR with a read-only PAT.
echo $GHCR_PAT_READONLY | docker login ghcr.io -u faridlab --password-stdin

# Up the stack.
docker compose --env-file .env.prod pull
docker compose --env-file .env.prod up -d

# Sanity.
docker compose logs -f __project__-service
curl -fsS https://api.${DOMAIN}/health
```

## Update beta (roll forward)

Three deploy patterns depending on what changed.

### Single service from a CI-built image (fastest, doesn't rebuild)

```bash
# CI just pushed __project__-service:v0.5.2 to GHCR. Roll prod to it:
./scripts/deploy-service.sh __project__-service v0.5.2 SERVICE_TAG
# verify
curl https://api.__project__.com/health | jq '{ version, commit, built_at }'
```

### Bump multiple tags + roll all changed services

```bash
./scripts/bump-prod-tag.sh SERVICE_TAG v0.5.2
./scripts/bump-prod-tag.sh WEBAPP_CUSTOMER_TAG v0.3.1
./scripts/preflight-prod.sh                                   # validate locally first
git diff deployment/.env.prod                                 # review
git commit -am "chore(deploy): bump service v0.5.2, customer v0.3.1"
metaphor deploy push prod --skip-build                        # uses pre-built GHCR images
```

### Manual (when scripts don't fit)

```bash
ssh deploy@vps
cd /srv/__project__
sed -i "s/^SERVICE_TAG=.*/SERVICE_TAG=v0.5.2/" .env.prod      # pin
docker compose --env-file .env.prod pull                      # only changed images get pulled
docker compose --env-file .env.prod up -d                     # only changed services restart
docker compose logs -f --tail=100 __project__-service
```

## Roll back

```bash
# Flip *_TAG entries in .env.prod to the previous SHA, then:
docker compose --env-file .env.prod pull
docker compose --env-file .env.prod up -d
```
Previous images stay in GHCR; don't prune aggressively.

## Migrations

`__project__-service migrate` exists as an argv subcommand but is a **placeholder** — it logs a warning and exits 0 so compose's one-shot migrations container doesn't crash. The app-level `MigrationManager` in `src/infrastructure/database/migrations/` is a compile-time stub (flagged as "Mock implementation to avoid SQLx compile-time validation"), and real module migrations live under each `modules/*/migrations/` and are applied by the `metaphor` CLI.

Until the binary's `migrate` subcommand is wired to a real `MigrationManager`, run migrations from a dev box against the deployed DB:

```bash
# Tunnel through SSH. Postgres is bound to 127.0.0.1:5432 on the VPS
# (commit 82da16d). Don't use `5433:postgres:5432` — the Docker DNS name
# isn't resolvable in the SSH host context and the handshake drops.
ssh -N -L 5433:127.0.0.1:5432 deploy@vps &
DATABASE_URL=postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@127.0.0.1:5433/$POSTGRES_DB \
  metaphor migration run-all
```

Replace the placeholder body in `run_migrate_subcommand()` (in `apps/__project__-service/src/main.rs`) once the framework plumbing is available, and delete this section.

## File-serving verification (mode A / B / C)

```bash
# Mode B (default): authenticated 302 to MinIO presigned URL.
curl -fsS -H "Authorization: Bearer $JWT" \
  -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://bucket.${DOMAIN}/product/image/demo.jpg

# Mode A (public fast-path): no service hop, direct MinIO.
curl -fsS https://bucket.${DOMAIN}/public/product/image/demo.jpg -o demo.jpg

# Mode C (raw presigned): service issues a URL, client hits MinIO directly.
curl -fsS "https://s3.${DOMAIN}/__project__-private/product/image/demo.jpg?X-Amz-Signature=…"
```

## Monitoring

- Grafana: `https://grafana.${DOMAIN}` — initial admin login uses `GRAFANA_ADMIN_PASSWORD` from `.env.prod`.
- Three dashboards ship under the **__PROJECT__** folder: Golden Signals, Postgres Health, Host & Container Resources.
- Five alerts ship under **Alerting → Alert rules → __PROJECT__ → golden-signals**: API 5xx rate, API p95 latency, Postgres connection saturation, host disk > 80 %, container restart loop. Rules live in `grafana/provisioning/alerting/rules.yml`.
- Alert routing: all alerts → `email-ops` contact point; `severity=critical` alerts repeat every 1h, `severity=warning` every 4h. The recipient address is hardcoded at `grafana/provisioning/alerting/contact-points.yml` (Grafana doesn't expand env vars inside provisioned alert settings) — edit the file and `docker compose restart grafana` to change it, or add extras through the Grafana UI.
- Community dashboards worth importing through the UI after first boot:
  - **Node Exporter Full** — Grafana.com ID `1860`
  - **Docker cAdvisor** — Grafana.com ID `14282`

## Backups

Nightly `pg_dump`:
```bash
sudo install -m 0755 /srv/__project__/backups/pg-backup.sh /usr/local/bin/
sudo mkdir -p /var/backups/pg && sudo chown deploy:deploy /var/backups/pg
echo '15 2 * * * deploy /usr/local/bin/pg-backup.sh >> /var/log/pg-backup.log 2>&1' \
  | sudo tee /etc/cron.d/pg-backup
```

Weekly off-site push via restic:
```bash
# One-time: create /etc/default/restic (chmod 600) with RESTIC_REPOSITORY,
# RESTIC_PASSWORD, B2_ACCOUNT_ID, B2_ACCOUNT_KEY. Then:
sudo restic -r "$RESTIC_REPOSITORY" init
sudo install -m 0755 /srv/__project__/backups/restic-push.sh /usr/local/bin/
echo '30 3 * * 0 deploy /usr/local/bin/restic-push.sh >> /var/log/restic-push.log 2>&1' \
  | sudo tee /etc/cron.d/restic-push
```

Monthly repo integrity check (catches B2-side bit-rot before you need a restore). Reads ~10 % of pack data per run, so the whole repo is sampled over ~10 months:
```bash
sudo install -m 0755 /srv/__project__/backups/restic-check.sh /usr/local/bin/
{ echo 'MAILTO=ops@__project__.com';
  echo '0 4 1 * * deploy /usr/local/bin/restic-check.sh >> /var/log/restic-check.log 2>&1'; } \
  | sudo tee /etc/cron.d/restic-check
```
A non-zero exit emails the operator via `MAILTO`. If you don't have local mail set up, swap that for a webhook in `restic-check.sh` (curl to a status endpoint or Slack).

**Restore drill (run once before beta):**
```bash
latest=$(ls -1t /var/backups/pg/__project__-*.sql.gz | head -1)
docker compose exec -T postgres \
  psql -U $POSTGRES_USER -c "CREATE DATABASE __project___restore;"
gunzip -c "$latest" \
  | docker compose exec -T postgres \
      psql -U $POSTGRES_USER -d __project___restore
# Sanity-check a row count, then drop __project___restore.
```

## Troubleshooting

- **`curl https://api.${DOMAIN}` returns TLS error** — DNS probably hasn't propagated; check `dig api.${DOMAIN}`. Caddy logs: `docker compose logs caddy`.
- **`__project__-service` restart loop** — `docker compose logs __project__-service`. The most common cause is `DATABASE_URL` wrong / postgres not yet ready; compose should handle ordering via `depends_on: condition: service_healthy`.
- **`bucket.${DOMAIN}/<key>` returns 404 from Rust** — the `storage_key` isn't in `stored_files`. Verify an upload happened: `docker compose exec postgres psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT storage_key FROM stored_files LIMIT 5;"`.
- **`bucket.${DOMAIN}/<key>` returns 302 to 127.0.0.1 or minio:9000** — `MINIO_PUBLIC_ENDPOINT` in `.env.prod` is wrong; should be `https://s3.${DOMAIN}`.

## Known gaps (tracked against DEPLOYMENT-PLAN.md)

1. **Dep-pin mismatch.** `__project__-service` pins framework crates to `tag = v2.0.0` but `backbone-sapiens` / `backbone-bucket` still reference `branch = main`. Service fails to build. Fix upstream + `metaphor sync --update`. See plan's "Pre-flight before execution".
2. **`migrate` subcommand is a placeholder.** Compose's `migrations` service starts, logs a warning, and exits 0 — it does not apply SQL. Real migrations still flow through `metaphor migration run-all`. See "Migrations" above.
3. **Webapp + Admin `pnpm-lock.yaml` not generated.** Vite + React + TS scaffolds exist under `apps/__project__-webapp-provider/` and `apps/__project__-webapp-admin/`, but the Dockerfile uses `pnpm install --frozen-lockfile`. First build requires the operator to generate and commit a lockfile:
   ```bash
   cd apps/__project__-webapp-provider && pnpm install && git add pnpm-lock.yaml
   cd apps/__project__-webapp-admin  && pnpm install && git add pnpm-lock.yaml
   ```
   Repeat whenever `package.json` changes.
4. **Metric names unverified.** Alert rules and dashboards assume `http_requests_total` / `http_request_duration_seconds_bucket` from backbone-observability. If the actual emitted names differ (e.g. `axum_http_requests_total`), both the dashboards under `grafana/provisioning/dashboards/` and the rules under `grafana/provisioning/alerting/rules.yml` need to be renamed in lockstep. Verify via `curl http://__project__-service:9090/metrics | grep -E '^# TYPE http'` once the service starts.
