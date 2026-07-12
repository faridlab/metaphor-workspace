# Deployment Plan — __PROJECT__ Beta on Single VPS (Docker)

> **What this is:** architecture and rationale — the *why* behind the single-VPS Docker stack, subdomain map, file-serving modes, and observability choices.
>
> **Looking for operator procedures?** They live in:
> - [PRODUCTION-DEPLOYMENT.md](PRODUCTION-DEPLOYMENT.md) — first-time deploy walkthrough
> - [UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md) — release loop, rollback, deployment history
> - [DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md) — `metaphor docker` / `metaphor deploy` CLI reference
> - [deployment/README.md](../deployment/README.md) — VPS-side runbook (backups, monitoring, restore drill)

## Context

- **Goal:** ship a beta of `__project__-mobile-provider` next week. The mobile app talks to a Rust backend (`__project__-service`) plus three React/TS webapps (customer `__project__-webapp-customer`, provider `__project__-webapp-provider`, admin `__project__-webapp-admin`).
- **Constraint:** one VPS, Docker only, **no source code on the box** — only built images + binaries + config. Each service reachable via its own subdomain.
- **Workspace shape today:**
  - [apps/__project__-service](../apps/__project__-service) — Axum + sqlx + Redis. Prometheus `/metrics` on `:9090`, REST `:3000`, gRPC `:50051`. Migrations driven by `backbone_orm::migrations`. SMTP + OTLP already wired in config.
  - [apps/__project__-webapp-provider](../apps/__project__-webapp-provider) — empty; to be scaffolded (Vite + React + TS).
  - `apps/__project__-webapp-admin` — does not exist yet; to be scaffolded alongside.
  - [apps/__project__-mobile-provider](../apps/__project__-mobile-provider) — KMP; **not deployed to VPS**, only needs a stable HTTPS API base URL.
  - [deployment/](../deployment) — empty. Net-new.

---

## Architecture (single VPS, Docker)

```
                           ┌────────────────────────────┐
   *.__project__.com  ──443──▶│  Caddy reverse proxy       │  (auto-TLS via Let's Encrypt)
                           │  (edge container)          │
                           └──────────────┬─────────────┘
                                          │  docker network: edge
        ┌─────────────────────┬───────────┼──────────────┬──────────────────────┐
        ▼                     ▼           ▼              ▼                      ▼
  app.__project__.com      api.__project__.com  grpc...   provider…  admin…      grafana…
  (customer / nginx)    (__project__-service REST)     (provider, admin / nginx)  (monitoring)
                              │
                              │  docker network: backend (private)
                              ▼
                ┌──────────────────────────────────┐
                │  postgres  │  redis  │  minio    │
                │  (named volumes, no host port)   │
                └──────────────────────────────────┘
                              │
                              │  docker network: observability (private)
                              ▼
        prometheus · grafana · loki · promtail · cadvisor · node-exporter · uptime-kuma
```

### Subdomain map

| Subdomain | Target container | Purpose |
|---|---|---|
| `api.__project__.com` | `__project__-service:3000` | REST for mobile + webapps |
| `grpc.__project__.com` | `__project__-service:50051` | gRPC (h2c upstream) |
| `app.__project__.com` | `__project__-webapp-customer:80` | Customer-facing webapp (nginx static) |
| `provider.__project__.com` | `__project__-webapp-provider:80` | Provider-facing webapp (nginx static) |
| `admin.__project__.com` | `__project__-webapp-admin:80` | Admin panel (nginx static, separate build) |
| `download.__project__.com` | `__project__-webapp-download:80` | Public download page for the provider mobile app (used while not on Play Store / App Store). Binaries hosted externally (GitHub Releases or MinIO public bucket), NOT baked into this image. |
| `bucket.__project__.com` | `__project__-service:3000` | **Default** file serving (auth-aware handler — option B). See [File serving](#file-serving-backbone-bucket-three-modes). |
| `s3.__project__.com` | `minio:9000` | Raw presigned-URL serving (option C) + public fast-path for option A |
| `invoice.__project__.com` | `__project__-service:3000` | Public, unauthenticated receipt page. Caddy rewrites `/{invoiceId}` → service `/invoice/{invoiceId}`. URL is shared with customers via WhatsApp / SMS so they can view their receipt in a browser. |
| `grafana.__project__.com` | `grafana:3000` | Dashboards (basic-auth + IP allowlist) |
| `status.__project__.com` | `uptime-kuma:3001` | Public status page |

> Customer, provider, and admin ship as three separate nginx images with independent builds. A shared `packages/ui` workspace is fine later, but each bundle must never accidentally include another role's code.

---

## Build & ship model: image-only, no source on VPS

1. **Build locally** — multi-stage Dockerfiles produce slim runtime images:
   - **__project__-service**: `rust:1-slim` builder → `gcr.io/distroless/cc-debian12` runtime (~25 MB image, statically linked binary, no shell, no source).
   - **__project__-webapp-customer** / **__project__-webapp-provider** / **__project__-webapp-admin**: `node:20-alpine` builder (`pnpm build`) → `nginx:alpine` serving `/dist`. SPA fallback baked into `nginx.conf`. Separate Dockerfile per app; shared base.
   - **migrations**: one-shot image running `__project__-service migrate` and exiting 0. Same Rust binary, different entrypoint.
2. **Push to GHCR** — `ghcr.io/faridlab/{__project__-service,__project__-webapp-customer,__project__-webapp-provider,__project__-webapp-admin}:<git-sha>` and `:beta`. Free, tied to GitHub auth, zero extra infra.
   - Laptop auth: `echo $GHCR_PAT | docker login ghcr.io -u faridlab --password-stdin`
   - VPS auth: same, with a **read-only** PAT.
3. **VPS deploy = manual SSH + compose** (explicit control for beta):
   ```bash
   ssh deploy@vps
   cd /srv/__project__
   docker compose --env-file .env.prod pull
   docker compose --env-file .env.prod up -d
   ```
   Files on the VPS: `compose.yaml`, `.env.prod`, `caddy/Caddyfile`, monitoring configs, named volumes. **Zero source code.**
4. **Tagging:** every build carries both `:<git-sha>` (immutable — what compose pins to) and `:beta` (moving pointer for humans). Roll forward or back by flipping the `*_TAG` entries in `.env.prod`.
5. **CI automation is out of scope for beta.** Manual stands up faster and fails more loudly. Revisit after launch.

---

## Files to create (under [deployment/](../deployment))

```
deployment/
├── compose.yaml                  # full stack, single-host
├── .env.prod.example             # secret template (committed; real .env.prod NOT committed)
├── caddy/
│   └── Caddyfile                 # subdomain routing + auto-TLS
├── prometheus/
│   └── prometheus.yml            # scrape __project__-service:9090, cadvisor, node-exporter
├── loki/
│   └── loki-config.yaml          # filesystem chunks, 14-day retention
├── promtail/
│   └── promtail-config.yaml      # tail docker container logs
├── grafana/
│   └── provisioning/             # datasources (prom + loki) + 3 starter dashboards
├── backups/
│   └── pg-backup.sh              # nightly pg_dump → /var/backups, restic push off-site
└── README.md                     # operator runbook (deploy, rollback, restore)
```

Per-app Dockerfiles live with the app:

- `apps/__project__-service/Dockerfile` (shared image; `CMD` switches `serve` vs `migrate`)
- `apps/__project__-webapp-customer/Dockerfile` + `apps/__project__-webapp-customer/nginx.conf`
- `apps/__project__-webapp-provider/Dockerfile` + `apps/__project__-webapp-provider/nginx.conf`
- `apps/__project__-webapp-admin/Dockerfile` + `apps/__project__-webapp-admin/nginx.conf`
- `apps/__project__-webapp-download/Dockerfile` + `apps/__project__-webapp-download/nginx.conf`

---

## Reverse proxy: Caddy

Why Caddy over Traefik/nginx for a beta on a single VPS:

- Automatic Let's Encrypt — zero cert plumbing.
- ~15-line `Caddyfile` for the full subdomain map.
- h2c reverse proxy for gRPC works out of the box.
- No label sprawl in `compose.yaml` (Traefik's main downside at small scale).

If the setup later grows to multi-node or needs dynamic config-from-labels, revisit Traefik.

---

## File serving (backbone-bucket): three modes

`backbone-bucket` is a metadata store + signed-URL generator + **mode-B Axum router** as of v0.1.0 (`69d48de`). It does not serve file bytes itself — bytes come from MinIO either directly (modes A/C) or via a service-issued redirect (mode B). The deployment supports all three modes, with **option B as the default** so most callers get pretty URLs + auth without thinking about it.

### Mode B — Auth-aware handler (default, `bucket.__project__.com/<key>`)

`bucket.__project__.com/*` → Caddy → `__project__-service` → upstream [`serving_router`](../modules/backbone-bucket/docs/serving.md):

1. `AuthExtractor` (consumer-supplied `FromRequestParts`) resolves the caller identity from the JWT/cookie.
2. Handler looks up the `StoredFile` by `storage_key` (backed by the new unique index from migration `018_add_stored_files_storage_key_index`).
3. `AuthzPolicy<Identity>::decide(&identity, &file)` — consumer-supplied; starts from `DefaultOwnerOnlyPolicy` and extends to cover `public/`, `FileShare` tokens, etc.
4. **302 redirect** to a SigV4-signed MinIO URL via `ObjectStorage::presigned_get` (default response strategy — `ServingMode::Redirect`). Alternative strategies (`Stream`, `SignedUrl`) ship in the same handler if a caller needs them.

The service stays out of the bandwidth path — only the auth check + redirect runs through Rust. The presigned URL's `X-Amz-Expires` lets the browser cache the object for the TTL window.

```
GET https://bucket.__project__.com/product/image/foo.jpg
  → __project__-service: AuthExtractor → lookup → AuthzPolicy
  → 302 https://s3.__project__.com/__project__-private/product/image/foo.jpg?X-Amz-Signature=…
```

**Why default:** correct by construction. Anyone calling the bucket from app code gets auth enforcement for free.

### Mode A — Public fast-path (`bucket.__project__.com/public/*`)

For hot, world-readable assets (product photos, marketing images, thumbnails) where the auth check + redirect is wasted work. Caddy carves out a path prefix and proxies straight to a **public** MinIO bucket:

```
GET https://bucket.__project__.com/public/product/image/foo.jpg
  → Caddy → MinIO public bucket (no service hop)
```

Selection rule baked into upload code: anything written under the `public/` prefix lands in the public MinIO bucket; everything else lands in private buckets and goes through mode B.

**Caveat:** anything in the public bucket is world-readable to anyone who guesses the URL. **Never put PII or user uploads there.** Convention enforced in the upload service, not at the storage layer.

### Mode C — Raw presigned URL (`s3.__project__.com/...`)

The low-level escape hatch — clients/back-end code that already hold a presigned URL hit MinIO directly. This is what the `CdnService` in `backbone-bucket` emits today; mode B's redirect lands here. Also used by direct-upload flows (browser → MinIO with a presigned PUT, bypassing the service for upload bandwidth).

### Caddyfile sketch

The upstream example mounts the serving router at `/cdn` (`.nest("/cdn", serving)`). To keep pretty URLs at the root of `bucket.__project__.com/<key>` while still respecting that mount point, Caddy rewrites the request path before proxying to the service. Mode A's `/public/*` carve-out goes straight to MinIO with no service hop.

```caddy
bucket.__project__.com {
    # Mode A — public fast-path: strip /public and proxy to the public bucket.
    handle_path /public/* {
        reverse_proxy minio:9000 {
            header_up Host __project__-public.minio.local
        }
    }
    # Mode B — default: rewrite to /cdn/<key> so the serving_router mount matches.
    handle {
        rewrite * /cdn{uri}
        reverse_proxy __project__-service:3000
    }
}

s3.__project__.com {
    reverse_proxy minio:9000
}
```

> If the rewrite feels fragile, the alternative is to live with `bucket.__project__.com/cdn/<key>` in URLs and drop the `rewrite` line. The auth + redirect behavior is identical either way.

### Upstream status: shipped in `backbone-bucket` v0.1.0

Mode B is no longer a prerequisite — it lives upstream as of commit `69d48de` (already pinned in `metaphor.lock`). Consumers plug in two traits, nothing else:

- **`AuthExtractor`** — any Axum `FromRequestParts` impl that yields the consumer's identity. `__project__-service` wires its existing JWT layer into this slot.
- **`AuthzPolicy<Identity>`** — decides whether an identity may read a given `StoredFile`. Starts from `DefaultOwnerOnlyPolicy` and grows to cover `public/` prefix reads, `FileShare` tokens, and admin override.

The wiring is ~40 lines on top of what `__project__-service` already does for the bucket module today (see [examples/serving/main.rs](../modules/backbone-bucket/examples/serving/main.rs) upstream). Step 4 of the implementation order collapses into pure app-side wiring — no upstream PR, no re-sync.

The `bucket.settings: {}` block in [apps/__project__-service/config/application.yml](../apps/__project__-service/config/application.yml) populates into the upstream `BucketConfig` / `StorageConfig::S3(S3Config)` / `ServingConfig` types. Field names below are authoritative (they map 1:1 to upstream struct fields); credential fields hold the **name** of the env var to read at startup, never the secret itself:

```yaml
bucket:
  enabled: true
  storage:
    kind: s3                              # StorageConfig::S3(...)
    endpoint: http://minio:9000           # S3Config.endpoint
    region: us-east-1                     # S3Config.region (any value; MinIO ignores it)
    access_key_env: MINIO_ACCESS_KEY      # name of env var holding the key
    secret_key_env: MINIO_SECRET_KEY
    private_bucket: __project__-private
    public_bucket: __project__-public        # omit to disable mode A
    public_endpoint: https://s3.__project__.com
    force_path_style: true                # required for MinIO
  serving:
    default_mode: redirect                # ServingMode — redirect | stream | signed_url
    public_prefix: public/                # mode A carve-out; also routes uploads to public_bucket
    presigned_ttl_seconds: 300            # ServingConfig.presigned_ttl (whole seconds)
```

**Upload side:** callers that want human-readable URLs (`public/product/image/slug.jpg`) use [`FileService::upload_with_key`](../modules/backbone-bucket/docs/serving.md#key-naming); everything else uses `FileService::upload` (auto-UUID key). Keys that start with `serving.public_prefix` land in `public_bucket` automatically; everything else lands in `private_bucket`.

> ⚠️ **`upload_with_key` does not gate who may write under `public/*`.** The `AuthzPolicy` trait controls *reads*. Upload call-sites in `__project__-service` must enforce "this user is allowed to publish to the public namespace" before calling `upload_with_key` with a `public/` key — otherwise any authenticated user can drop files into a world-readable bucket.

> The deprecated `CdnService` (HMAC-signed URLs, not S3-compatible) is still exported from the module for one release; replace any lingering `cdn_service.get_or_generate_url(...)` call sites with `storage.presigned_get(&file.storage_key, ttl)` as part of the wiring PR. Module removes it in `v0.3.0`.

---

## Monitoring stack (open-source, Docker-standard)

Pre-wired because `__project__-service` already exposes Prometheus metrics on `:9090` and emits OTLP traces.

| Tool | Role | Why |
|---|---|---|
| **Prometheus** | Scrape metrics | Service already ships `/metrics`; de-facto standard. |
| **Grafana** | Dashboards + alerts | Standard pair with Prometheus + Loki. |
| **Loki + Promtail** | Container log aggregation | Lighter than ELK; tails Docker logs by label. |
| **cAdvisor** | Per-container CPU/mem/IO | Plug-and-play. |
| **Node Exporter** | Host metrics (disk, load, net) | Standard for VPS health. |
| **Uptime Kuma** | External uptime + public status page | Cheap insurance; nice status page for beta users. |
| *(deferred)* Tempo / Jaeger | Distributed tracing | OTLP emission stays on; add a collector post-beta if needed. |

Grafana dashboards provisioned on day 1: **Service Golden Signals**, **Postgres Health**, **Container/Host Resources**.

Alerts (Grafana → email or Telegram via the SMTP config already in `__project__-service`): API 5xx rate, p95 latency, DB connection-pool saturation, disk > 80 %, container restart loop.

---

## Data, secrets, backups

- **Postgres 16** in container, data on named volume `pgdata`. No host port published — reachable only on the `backend` Docker network.
- **Redis 7** in container, `redisdata` volume, also private.
- **MinIO** (S3-compatible) for `backbone-bucket`. Single-node mode is fine for beta; volume `miniodata`. **Two buckets** auto-created on boot via a small `mc` init container: `__project__-public` (anonymous-read policy, fronted by `bucket.__project__.com/public/*`) and `__project__-private` (default-deny, accessed only via presigned URLs from mode B). Console port `:9001` stays bound to localhost only.
- **Secrets:** `.env.prod` on the VPS only, `chmod 600`, owned by the deploy user. Loaded by `compose.yaml` via `env_file:`. `.env.prod.example` committed for shape; real file **never** committed.
- **Backups:**
  - Nightly cron: `pg_dump` → `/var/backups/pg/` (7-day retention).
  - Weekly: `restic` push of `/var/backups` and the MinIO bucket to off-site (e.g. Backblaze B2).
  - Restore drill documented in `deployment/README.md` — **actually run it once before beta**.

---

## Migration & startup ordering

Compose `depends_on` + healthchecks:

1. `postgres` healthy (`pg_isready`)
2. `redis` healthy (`redis-cli ping`)
3. `migrations` runs once, exits 0 (one-shot service)
4. `__project__-service` starts, waits for `/health` ready
5. `caddy` starts last, begins routing

This avoids the classic "service boots before DB is ready" race.

---

## Deploy workflow

The day-to-day deploy commands live in [DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md) (CLI reference), [PRODUCTION-DEPLOYMENT.md](PRODUCTION-DEPLOYMENT.md) (first deploy), and [UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md) (updates and rollback). This document only covers architectural choices; see those for the operator-facing procedures.

---

## Verification checklist (before declaring beta-ready)

- [ ] `curl https://api.__project__.com/health` → 200 from outside the VPS
- [ ] Mobile app, pointed at `api.__project__.com`, completes login + one full booking flow
- [ ] `https://app.__project__.com` (customer) loads, hits API, shows data
- [ ] `https://provider.__project__.com` (provider) loads, hits API, shows data
- [ ] `https://admin.__project__.com` loads, admin login works, CRUD round-trip succeeds
- [ ] **Mode B (default):** `https://bucket.__project__.com/<private-key>` returns the file (302 → MinIO presigned) when authed; returns 401/403 when not
- [ ] **Mode A (public):** `https://bucket.__project__.com/public/product/image/<key>` serves a known seeded asset directly from MinIO with no service hop (verify via `docker compose logs __project__-service` — no entry)
- [ ] **Mode C (raw):** a manually-generated presigned URL on `s3.__project__.com` downloads; the same URL after expiry returns 403
- [ ] Public-bucket guard: confirm no PII / private content has accidentally been uploaded under the `public/` prefix (grep upload sites for `public/` literal usage)
- [ ] `https://grafana.__project__.com` shows non-zero metrics on the Golden Signals dashboard
- [ ] Trigger a synthetic 500; confirm Grafana alert reaches inbox
- [ ] `pg_dump` cron fires; backup file appears; **test restore into a scratch container**
- [ ] Reboot the VPS; full stack comes back up unattended (`restart: unless-stopped` everywhere)
- [ ] `docker compose down && up -d` preserves data (volumes mounted correctly)
- [ ] TLS certs auto-issued on every subdomain (check `caddy logs`)
- [ ] Disk usage budget: < 40 % after a week of normal traffic + log retention

---

## Out of scope for beta (intentional)

- Multi-node / HA (single VPS is the constraint).
- Blue/green deploys (image-tag swap + 1–2 s downtime is acceptable for beta).
- Distributed-tracing UI (OTLP emission stays on; collector deferred).
- Managed DB / Redis (cost; revisit post-beta if the VPS becomes a bottleneck).
- CDN in front of the webapps (add later if needed).

---

## Path to horizontal scale (forward-looking, not for beta)

Adding a load balancer in front of multiple service replicas is **out of scope for beta**, but the design choices below keep that door open. When traffic actually demands it, the migration looks like this:

| Concern | Beta state | What changes when you scale out |
|---|---|---|
| **App tier statelessness** | `__project__-service` keeps sessions in Redis, files in MinIO/S3, no local disk state. | Already LB-friendly. Add replicas behind a load balancer (cloud LB, or Caddy with multiple `reverse_proxy` upstreams). |
| **Postgres** | Single container on the VPS. | Move to managed Postgres (RDS / Neon / Supabase) **before** adding app replicas — a single-node DB is the real bottleneck, not the app. |
| **Redis** | Single container on the VPS. | Move to managed Redis or a small Redis cluster. App code already talks to it via URL — only `REDIS_URL` changes. |
| **Object storage** | Single-node MinIO. | Switch to distributed MinIO (4+ nodes) or external S3 (R2 / B2 / AWS). `backbone-bucket` is S3-compatible — endpoint swap. |
| **TLS termination** | Caddy on the VPS, certs on local volume. | Either (a) terminate TLS at the cloud LB and pass http to Caddy, or (b) keep Caddy doing TLS with shared cert storage (e.g. Caddy's S3/Redis storage plugin). Both work. |
| **Migrations** | One-shot `migrations` container before service starts. | Becomes a release-time gate (CI step, or leader-election sidecar) so it runs **once per release**, not once per node. |
| **Logs / metrics** | Loki on local filesystem, Prometheus scraping local targets. | Loki → object-storage backend (S3); Prometheus → remote-write to a managed sink (Grafana Cloud, Mimir) or a dedicated obs node. |
| **Deploy mechanism** | Manual SSH to one host. | Ansible, or a small CD pipeline that hits each node — same `compose.yaml`, different inventory. |

**Order of operations when the time comes:** managed DB → managed Redis → external object storage → second app node behind LB → shared cert/log storage. Don't add the LB first; it just exposes the single-node infra as the bottleneck.

A separate `docs/SCALING-PLAN.md` should be written when there's real traffic data to design against. This section exists only to prove the beta plan doesn't paint us into a corner.

---

## Pre-flight before execution

- **DNS:** set A records for `api`, `grpc`, `app`, `provider`, `admin`, `download`, `bucket`, `s3`, `invoice`, `grafana`, `status` under `__project__.com` (or the real beta domain) pointing at the VPS public IP **before** Caddy first boots — otherwise cert issuance will fail.
- **VPS baseline:** Ubuntu 22.04/24.04 LTS, Docker Engine 26+ (not distro `docker.io`), `ufw` allowing 22/80/443 only, fail2ban on SSH, non-root `deploy` user in the `docker` group.
- **GHCR PATs:** one write-scope PAT on the laptop, one read-only PAT on the VPS.
- **Frontend lockfiles:** Vite + React + TS scaffolds exist under [apps/__project__-webapp-customer](../apps/__project__-webapp-customer), [apps/__project__-webapp-provider](../apps/__project__-webapp-provider), and [apps/__project__-webapp-admin](../apps/__project__-webapp-admin), but the Dockerfiles build with `pnpm install --frozen-lockfile`. First image build requires the operator to run `pnpm install` locally in each app directory and commit the resulting `pnpm-lock.yaml`. Repeat whenever `package.json` changes.
- **Upstream dep-pin mismatch (blocks `__project__-service` build):** the service pins framework crates to `tag = "v2.0.0"` in [apps/__project__-service/Cargo.toml](../apps/__project__-service/Cargo.toml), but [backbone-sapiens](https://github.com/faridlab/backbone-sapiens)'s and [backbone-bucket](https://github.com/faridlab/backbone-bucket)'s `Cargo.toml` still pin `branch = "main"`. Cargo treats these as two distinct sources and produces duplicate copies of `backbone-messaging` / `backbone-core`, surfacing as `expected IntegrationEventBus, found backbone_messaging::IntegrationEventBus` at [main.rs:478](../apps/__project__-service/src/main.rs#L478). **Fix upstream** (modules are read-only here): bump `backbone-sapiens` and `backbone-bucket` module `Cargo.toml` to `tag = "v2.0.0"` on all `backbone-*` deps, retag, then back here run `metaphor sync --update`. Verify with `cargo tree -d -p __project__-service` — no `backbone-messaging` listed twice.

---

## Implementation order (suggested)

1. `__project__-service` Dockerfile + distroless runtime, build + push green locally.
2. `deployment/compose.yaml` for **postgres + redis + migrations + __project__-service + caddy** only. Prove `api.__project__.com` works end-to-end from outside.
3. Add MinIO + the two buckets (public/private) + `s3.__project__.com` (mode C). Verify a presigned upload + download.
4. **Wire mode B into `__project__-service`** — upstream handler already ships in `backbone-bucket` v0.1.0, so this is app-side wiring only:
   - Populate the `bucket` block in [apps/__project__-service/config/application.yml](../apps/__project__-service/config/application.yml) with the `BucketConfig` / `S3Config` / `ServingConfig` YAML from [File serving](#file-serving-backbone-bucket-three-modes).
   - Construct `Arc<dyn ObjectStorage> = Arc::new(S3Storage::new(s3_cfg, serving_cfg)?)` in `build_app()` (currently `apps/__project__-service/src/main.rs:446` builds the bucket module with database only).
   - Add `.with_config(bucket_config).with_storage(storage)` to the existing `BucketModule::builder()` chain.
   - Implement an `AuthExtractor` impl on `__project__-service`'s existing identity type (reusing the JWT/session layer already used by `sapiens`). Implement a `MyPolicy` `AuthzPolicy` that starts from `DefaultOwnerOnlyPolicy` and allows the `public/` prefix.
   - `.nest("/cdn", bucket_module.serving_router::<MyUser>(Arc::new(MyPolicy))?)` next to the existing `.nest("/api/v1/bucket", bucket_router)`.
   - Run `metaphor migration run-all` on the deploy target to pick up migration `018_add_stored_files_storage_key_index` before the first serving request (the handler relies on the `UNIQUE INDEX` on `stored_files.storage_key`).
   - Wire `bucket.__project__.com` in Caddy with the `/public/*` mode-A carve-out and the mode-B path rewrite from the Caddyfile sketch.
5. Scaffold `__project__-webapp-customer` + `__project__-webapp-provider` + `__project__-webapp-admin`, add Dockerfiles + nginx configs, wire subdomains.
6. Layer in the monitoring stack + Grafana dashboards + alerts.
7. Backups cron + restore drill.
8. Run the verification checklist. Hand the URL to beta testers.
