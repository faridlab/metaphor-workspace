# Per-app orientation

The app types this workspace template ships. `__project__` is the product
name placeholder — replace it everywhere on clone (see the workspace
[README](../README.md)).

## `__project__-service` — `backend-service`

The composition service: Axum + SQLx + Tokio binary that composes the
pinned `backbone-*` domain modules into one router and one database.
Business logic lives in the modules — this app composes, bootstraps, and
serves. Dev: `127.0.0.1:3000` with cargo-watch hot reload inside
`compose.dev.yaml`. Read its `CLAUDE.md` before any edit — the regen-safety
law (`user_owned:` / `// <<< CUSTOM` markers) is enforced there.

## `__project__-webapp-{provider,admin,customer,download}` — `webapp`

Vite + React + TypeScript, pnpm-managed. In dev they run on the HOST via
`pnpm dev` by default (ports 5173–5176); the containerized variants sit
behind the opt-in `frontends` compose profile. Never run host and container
Vite for the same app at once — they fight over the port.

## `__project__-mobile-provider` — `mobileapp`

Kotlin Multiplatform + Compose, offline-first sync; talks to the local
backend via `API_BASE_URL`. See its README for the emulator workflow.

## Dev-stack port map (compose.dev.yaml)

| Port | What |
|---|---|
| 3000 | `__project__-service` (HTTP) — probe as `127.0.0.1:3000`, not `localhost` |
| 5432 / 6379 / 9000-9001 | postgres / redis / minio |
| 5173 / 5174 / 5175 / 5176 | webapp dev servers (host `pnpm dev`, or opt-in `frontends` profile) |
