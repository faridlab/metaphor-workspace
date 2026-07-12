# Local Development

How to run the __project__ stack on your laptop.

The local environment is defined in [`metaphor.deploy.yaml`](../metaphor.deploy.yaml) under `environments.dev`. It has no `host:` field, so the `metaphor docker` family operates on it locally rather than over SSH. Dev uses a dedicated [`deployment/compose.dev.yaml`](../deployment/compose.dev.yaml) — kept separate from the prod stack ([`compose.yaml`](../deployment/compose.yaml)) so neither file has to know about the other.

## Prerequisites

- **Docker** + **Docker Compose** (v2 — `docker compose`, not `docker-compose`)
- **`metaphor` CLI** on PATH — see [metaphor-cli releases](https://github.com/faridlab/metaphor-cli/releases)
- **`metaphor-dev` plugin**: `metaphor plugin add metaphor-dev@latest`
- **`git`** — used by `metaphor sync` and tag derivation

A local Rust toolchain or Node is **not** required — apps build and run inside containers.

## First-time setup

```bash
git clone <this-repo>
cd __project__-metaphor

metaphor sync                       # clone upstream modules to pinned refs
metaphor docker up --env dev        # data stores + apps with hot reload
```

[`deployment/.env.dev`](../deployment/.env.dev) is committed with safe local defaults — no copy step from `.env.prod.example`. Edit it only if you need to override a value (port, log level, etc.).

## What runs and where

```
                 +------------------------------+
                 |  __project__-service            |  127.0.0.1:3000
                 |  cargo watch -x run          |  (in container)
                 +------------------------------+
                            |
        +-------------------+-------------------+
        |                   |                   |
   +----------+        +----------+        +----------+
   | postgres |        |  redis   |        |  minio   |
   |  :5432   |        |  :6379   |        | :9000/01 |
   +----------+        +----------+        +----------+

   __project__-webapp-provider   127.0.0.1:5173   (host `pnpm dev` by default)
   __project__-webapp-admin      127.0.0.1:5174   (host `pnpm dev` by default)
   __project__-webapp-customer   127.0.0.1:5175   (host `pnpm dev` by default)
   __project__-webapp-download   127.0.0.1:5176   (host `pnpm dev` by default)
```

All container ports bind to `127.0.0.1` only. Source is bind-mounted from `apps/<name>/` into each container; build artifacts (Cargo target dir, registry, git cache) live in named volumes so they survive `down`/`up`.

**Frontends run on the host by default** (faster Vite HMR, better IDE support). The container-based frontends are disabled by an opt-in compose profile — see [Frontends: host vs container](#frontends-host-vs-container) below.

## Run all services

```bash
metaphor docker up --env dev          # data stores + backend (frontends excluded by default)
metaphor docker logs --follow         # tail every running service (Ctrl-C detaches, doesn't stop)
metaphor docker down                  # stop containers, keep volumes

# Frontends — host
cd apps/__project__-webapp-provider && pnpm install && pnpm dev   # :5173
cd apps/__project__-webapp-admin    && pnpm install && pnpm dev   # :5174
cd apps/__project__-webapp-customer && pnpm install && pnpm dev   # :5175
cd apps/__project__-webapp-download && pnpm install && pnpm dev   # :5176
```

The first `up` is slow:

| Step | Cold | Warm |
|---|---|---|
| Pull `postgres` / `redis` / `minio` images | ~30s | seconds |
| Build `__project__-service` dev image (apt + cargo-watch) | ~2-3 min | seconds |
| `cargo watch` first compile (cooks every `backbone-*` git dep) | ~5-15 min | seconds (uses `cargo_target` volume) |

After that, code edits trigger sub-second rebuilds (cargo-watch). Frontend HMR comes from the host Vite dev servers and is instant.

## Frontends: host vs container

By default, [`compose.dev.yaml`](../deployment/compose.dev.yaml) puts `__project__-webapp-customer`, `__project__-webapp-provider`, `__project__-webapp-admin`, and `__project__-webapp-download` behind the `frontends` compose profile — they're skipped by `metaphor docker up --env dev`. Run them on the host with `pnpm dev`. Most teams prefer this for speed.

**To run frontends in containers instead**, uncomment one line in [`deployment/.env.dev`](../deployment/.env.dev):

```diff
- # COMPOSE_PROFILES=frontends
+ COMPOSE_PROFILES=frontends
```

Then `metaphor docker up --env dev` will start `__project__-webapp-customer` (`:5175`), `__project__-webapp-provider` (`:5173`), `__project__-webapp-admin` (`:5174`), and `__project__-webapp-download` (`:5176`) alongside the rest. First start adds ~1-2 min for `pnpm install --frozen-lockfile` (cached in a named `node_modules` volume after that).

For one-off container runs without changing the env file, name the services explicitly — `--service` overrides the profile gate:

```bash
metaphor docker up --env dev --service __project__-webapp-customer --service __project__-webapp-provider --service __project__-webapp-admin --service __project__-webapp-download
```

Don't run both host and container Vite for the same app — they fight over `:5173` / `:5174` / `:5175` / `:5176`.

## Run only some services

Use `--service <name>` (repeatable) to start a subset. Useful when you don't want to pay the full build cost or you're iterating in a different layer. `--service` also bypasses profile gates, so it's the way to run the (otherwise-disabled) frontend containers ad-hoc.

```bash
# Data stores only — useful when running an app outside Docker
metaphor docker up --env dev \
  --service postgres --service redis --service minio --service minio-init

# Backend + its deps (default behaviour)
metaphor docker up --env dev --service __project__-service

# Frontends in containers, one-off (skips the host pnpm dev workflow)
metaphor docker up --env dev \
  --service __project__-webapp-customer --service __project__-webapp-provider --service __project__-webapp-admin --service __project__-webapp-download
```

Compose resolves `depends_on` automatically, so `--service __project__-service` brings up postgres / redis / minio / minio-init too.

## Hot-reload workflow

Once the stack is up, leave it running. Edits on the host propagate into containers via bind mounts:

- **Rust** (`apps/__project__-service/src/**`) — `cargo-watch` re-runs `cargo run`. Compile-only feedback in seconds; full rebuilds when deps change.
- **Frontends** (`apps/__project__-webapp-customer/src/**`, `apps/__project__-webapp-provider/src/**`, `apps/__project__-webapp-admin/src/**`, `apps/__project__-webapp-download/src/**`) — Vite HMR pushes module updates to the browser instantly.

Tail a single service while iterating:

```bash
metaphor docker logs --follow --service __project__-service
```

## Environment variables

The dev environment reads [`deployment/.env.dev`](../deployment/.env.dev). Values are local-safe and **not secrets** — never reuse them outside this machine.

Most edits aren't necessary, but common overrides:

| Variable | Default | When to change |
|---|---|---|
| `POSTGRES_PASSWORD` | `__project__-dev` | Almost never |
| `JWT_SECRET` | dev-only 32-char string | Almost never |
| `MINIO_ROOT_PASSWORD` | `__project__-dev-pw` | Almost never |
| `LOG_LEVEL` | `debug` | Set to `info` for less verbose output |
| `LOG_FORMAT` | `text` | Set to `json` to mirror prod logging |
| `RATE_LIMIT_ENABLED` | `false` | Set to `true` to test rate-limit behavior |

The path is configurable per environment in [`metaphor.deploy.yaml`](../metaphor.deploy.yaml) (`environments.dev.env_file`).

## Database migrations

Migrations live across the upstream `backbone-*` modules. Apply them all against the dev Postgres:

```bash
metaphor migration run-all
```

The dev compose does **not** run migrations automatically. The prod stack has a `migrations` one-shot service ([compose.yaml](../deployment/compose.yaml)), but it's a placeholder today (see [deployment/README.md](../deployment/README.md)).

## Common commands

```bash
# Lifecycle
metaphor docker up --env dev                              # start everything (detached)
metaphor docker up --env dev --build                      # rebuild dev images first
metaphor docker up --env dev --service __project__-service   # only one service (+ its deps)
metaphor docker down                                      # stop, keep volumes
metaphor docker down --volumes                            # destructive — wipes pgdata, redis, minio

# Inspection
metaphor docker ps
metaphor docker logs --follow --service __project__-service
metaphor docker logs --tail 200 --service postgres

# Maintenance
metaphor docker restart --service __project__-service
metaphor docker build --service __project__-service          # rebuild a specific dev image

# Tests
metaphor test --affected --base=main
```

Full flag reference: [docs/DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md).

## Stopping & cleanup

```bash
metaphor docker down              # stop containers; volumes survive
metaphor docker down --volumes    # also wipe volumes — fresh DB / MinIO / Cargo cache
```

Wiping volumes is destructive: Postgres data, MinIO objects, Redis keys, **and** the Rust build cache + `node_modules` are gone. The next `up` will repeat the cold-build timings above. Only use when you genuinely want a clean slate.

## Troubleshooting

### `__project__-service` container fails to compile

The most common cause is the framework dep-pin gap flagged in [deployment/README.md](../deployment/README.md): `__project__-service` pins `backbone-*` crates to `tag = v2.0.0` while some upstream modules still reference `branch = main`. Fix upstream and `metaphor sync --update`. Data stores and frontends are unaffected — only the backend container will be unhealthy.

### Port conflicts on `:3000`, `:5173`, `:5432`, etc.

Another process is bound to the port. Find and kill it:

```bash
lsof -i :3000          # macOS / Linux
kill <PID>
```

If you can't free the port, change the host-side mapping in [`compose.dev.yaml`](../deployment/compose.dev.yaml).

### Frontend build fails with `pnpm install --frozen-lockfile`

Usually means `pnpm-lock.yaml` is out of date relative to `package.json`. Regenerate it:

```bash
docker run --rm -v "$PWD/apps/__project__-webapp-provider:/app" -w /app node:20-alpine \
  sh -c "corepack enable && pnpm install"
git add apps/__project__-webapp-provider/pnpm-lock.yaml
```

(Same for `__project__-webapp-admin`, `__project__-webapp-customer`, and `__project__-webapp-download`.)

### Upstream module out of date

```bash
metaphor sync --update      # re-resolve refs and update metaphor.lock
metaphor migration run-all  # apply any new migrations
```

### Docker daemon not running / permission denied

- macOS / Windows: start Docker Desktop
- Linux: `sudo systemctl start docker`, then add your user to `docker`: `sudo usermod -aG docker $USER` (re-login after)

### `compose file not found at deployment/compose.dev.yaml`

You haven't run `metaphor sync` yet, or the `compose_file` path under `environments.dev` in [`metaphor.deploy.yaml`](../metaphor.deploy.yaml) doesn't match the file on disk. Verify:

```bash
ls deployment/compose.dev.yaml
```

### Slow rebuilds even after the first cold run

The Cargo cache lives in named volumes (`cargo_target`, `cargo_registry`, `cargo_git`). If you ran `metaphor docker down --volumes`, they were wiped — next `up` will be cold again. To inspect:

```bash
docker volume ls | grep deployment_cargo
```

## See also

- [apps/__project__-service/README.md](../apps/__project__-service/README.md) — backend internals (DDD layout, modules composed)
- [apps/__project__-mobile-provider/README.md](../apps/__project__-mobile-provider/README.md) — mobile app (talks to the local backend via `API_BASE_URL`)
- [docs/DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md) — full `metaphor docker` flag reference
- [metaphor.deploy.yaml](../metaphor.deploy.yaml) — environment definitions
- [deployment/compose.dev.yaml](../deployment/compose.dev.yaml) — what dev services look like, networking, healthchecks
- [deployment/compose.yaml](../deployment/compose.yaml) — prod/uat stack (separate file by design)
