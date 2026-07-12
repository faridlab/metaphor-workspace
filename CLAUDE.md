# Metaphor Consumer Workspace

> Type: **consumer workspace** — a product repo that *uses* Metaphor. Upstream framework crates / modules are pulled in as pinned git dependencies via `metaphor.yaml` + `metaphor.lock`.
> This file orients Claude. Skills carry depth; load them on demand.

## What this is

A multi-app product. Upstream dependencies (e.g. `backbone-framework`, `backbone-<domain>`, `pheromone`) are declared in `metaphor.yaml` with `remote:` + `ref:`, resolved to commit SHAs in `metaphor.lock`, and synced into `modules/` on disk by `metaphor sync`. Apps live under `apps/` and consume modules via path or git dependency.

## Golden path

```bash
metaphor doctor                  # tooling + upstream health
metaphor sync                    # clone/update remote modules to pinned refs
metaphor info                    # where am I?
metaphor migration run-all       # bring DBs up to date
metaphor dev serve               # run the current app
```

## Rules

- **MUST** run `metaphor sync` after pulling changes that touch `metaphor.yaml` or `metaphor.lock`.
- **MUST** treat `modules/` as read-only clones of upstream repos — **NEVER** edit files inside `modules/*`. Fix upstream and re-sync.
- **MUST** pin versions in `metaphor.yaml` (`ref: v1.2.0` or commit SHA) for reproducibility.
- **MUST** check `metaphor.lock` into git.
- **NEVER** edit `metaphor.lock` by hand — regenerate via `metaphor sync --update`.
- **NEVER** copy files between apps — if they share code, promote to an upstream module instead.
- **MUST** declare every required runtime env var in the matching `.env.*.example` template. Compose stacks fail-fast on missing vars — no silent defaults.
- **MUST** use `{$VAR}` parse-time placeholders for Caddy site addresses (not `{env.VAR}` runtime form). Runtime placeholders don't apply to site address blocks and the stack will refuse to start.
- **MUST** declare every hand-written, non-schema-derived file under `apps/<app>/metaphor.codegen.yaml` → `user_owned:`. Files not listed there (and not protected by `// <<< CUSTOM` markers) are wiped on the next `metaphor schema generate --force`. See `apps/<app>/CLAUDE.md` for the per-app manifest.
- **SHOULD** use `metaphor dev` / `metaphor test` / `metaphor build` over raw `cargo` / `gradle`.
- **MUST** read a repo's own `CLAUDE.md` before working in it (each app under `apps/` and each upstream clone under `modules/` may carry its own). When entering a different repo, that repo's rules govern — follow them over assumptions carried in from elsewhere; on conflict, the more local `CLAUDE.md` wins.

## Workspace shape

```
./
├── metaphor.yaml          # projects[]: apps + remote modules
├── metaphor.lock          # resolved commit SHAs (check in)
├── modules/               # ← upstream clones (read-only; managed by sync)
│   └── <backbone-*>/
├── apps/                  # ← your product code
│   └── <app-name>/        # each has its own CLAUDE.md
│       └── metaphor.codegen.yaml   # codegen manifest: user_owned globs the generator must NEVER touch
├── deployment/            # compose.dev.yaml + compose.yaml, Caddy, observability, backups
│   ├── compose.dev.yaml   # daily driver: postgres+redis+minio+service hot-reload
│   ├── compose.yaml       # prod stack (single-VPS deploy)
│   ├── caddy/             # reverse proxy + TLS termination
│   └── .env.prod.example  # required vars; copied to .env.prod (gitignored) on the VPS
└── metaphor.deploy.yaml   # deployment manifest: envs (dev/uat/prod), services, image tags
```

> Single-service deploy / tag bump / env validation are built into the CLI
> (`metaphor deploy service|bump|preflight`) — no per-repo scripts needed.

## `metaphor.yaml` for consumers

```yaml
version: 1
projects:
  - name: backbone-framework
    type: crate
    path: ./modules/backbone-framework
    remote: https://github.com/faridlab/backbone-framework
    ref: main                              # tag/branch/SHA

  - name: my-service
    type: backend-service
    path: ./apps/my-service
    depends_on: [backbone-framework]

  - name: my-mobile
    type: mobileapp
    path: ./apps/my-mobile
```

Presence of any `remote:` entry = this is a **consumer workspace** (as opposed to a framework workspace that defines upstream).

## Per-app orientation

Each app inside `apps/` has its own `CLAUDE.md` matching its project type. Read that before editing the app:

- `backend-service` → Axum + SQLx + modules composition (`apps/__project__-service/`)
- `mobileapp` → Kotlin Multiplatform + Compose + offline-first sync (`apps/__project__-mobile-provider/`)
- `webapp` → Vite + React + TypeScript, pnpm-managed, served by nginx in prod (`apps/__project__-webapp-{customer,provider,admin,download}/`). In dev, opt in via `COMPOSE_PROFILES=frontends` — most teams run `pnpm dev` on the host for faster HMR.
- static download page → plain HTML/assets, no build step (`apps/__project__-github-download/`)

## Common tasks

- "Update to newer upstream" → edit `ref:` in `metaphor.yaml`, then `metaphor sync --update && metaphor migration run-all && metaphor test --affected`.
- "Add a new app" → `metaphor apps create <name> --type <backend-service|mobileapp|...>` (wires into `metaphor.yaml` automatically).
- "Run migrations across all DBs" → `metaphor migration run-all`.
- "Test only what I changed" → `metaphor test --affected --base=main`.
- "Bring up local dev stack" → `metaphor docker up --env dev` (uses `deployment/compose.dev.yaml`, hot-reload via cargo-watch). See `apps/__project__-service/CLAUDE.md` for the service-only alternative.
- "Deploy to prod" → `metaphor deploy preflight prod` first (validates env, secrets, image tags), then `metaphor deploy service prod <service> <tag>` (single service, records history) or `metaphor deploy push prod --skip-build --skip-migrate` (full stack). Reference: `docs/PRODUCTION-DEPLOYMENT.md`, `docs/UPDATING-DEPLOYMENTS.md`.
- "Bump a service image tag" → `metaphor deploy bump prod --service <service> --tag <tag>` (writes `*_TAG` to local `.env.prod` only; review + commit, then deploy).
- "Refresh Claude Code setup" → `metaphor agent claude update` (re-apply CLAUDE.md templates).

## Key files to read before editing

- `metaphor.yaml` — what upstream we track, what apps exist.
- `metaphor.lock` — the SHAs actually in use.
- `metaphor.deploy.yaml` — environments (dev/uat/prod), services, image tags.
- `apps/<current-app>/CLAUDE.md` — per-app rules.
- `deployment/compose.dev.yaml` / `compose.yaml` — local dev vs production stacks.
- `deployment/.env.prod.example` — every required prod env var (real `.env.prod` is gitignored, lives only on the VPS).

## Deeper knowledge (load on demand)

- Skill: `metaphor-cli-master` — full CLI surface.
- Skill: `backbone-cli-master` — Backbone-specific workflows.
- Skill: `backbone-modules-orchestrator` — composing modules into a service.
- Skill: `source-driven-development` — staying aligned with upstream source of truth.

## Anti-patterns

- Editing `modules/*` in-place (changes are wiped on next `sync`; fix upstream).
- Committing `metaphor.lock` changes without also updating `metaphor.yaml` (lock drift).
- Copy-paste between apps (creates drift; extract to a shared module instead).
- Adding a hand-written file inside a generator-owned tree (`src/application/service/`, `src/domain/entity/`, `migrations/`, …) without listing it under `user_owned:` in `metaphor.codegen.yaml`. The next `metaphor schema generate --force` will silently wipe it.
- Hand-editing a generator-emitted file outside its `// <<< CUSTOM ... // END CUSTOM` markers. Edits outside markers are clobbered on regen — wrap them, or list the whole file under `user_owned:` if it can't be expressed inside markers.
- Running `cargo build` inside `modules/*` (may pollute upstream working tree — use `metaphor build` which builds in the right place).
- Running `compose.dev.yaml` and `compose.yaml` simultaneously (both bind `127.0.0.1:5432` and will collide). Pick one.
- Hand-editing `deployment/.env.prod` on the VPS without updating `deployment/.env.prod.example` in git — the example is the contract; required vars are enforced at startup.
- Adding a Caddy site block with `{env.VAR}` for the host portion (Caddy resolves site addresses at parse time, so the runtime placeholder leaves the literal string in the address and TLS provisioning fails). Use `{$VAR}`.
