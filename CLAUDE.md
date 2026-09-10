# Metaphor Consumer Workspace

> Type: **consumer workspace** — a product repo that *uses* Metaphor. Upstream framework crates / modules are declared in `metaphor.yaml` (`remote:` + `ref:`), resolved to SHAs in `metaphor.lock`, synced into `modules/` by `metaphor sync`. Apps live under `apps/`.
> This file orients Claude; depth lives in referenced docs — load on demand.

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
- **MUST** treat `modules/` as read-only upstream clones — **NEVER** edit inside `modules/*` (wiped on next sync). Fix upstream, re-pin, re-sync.
- **MUST** pin refs in `metaphor.yaml`; check in `metaphor.lock`; **NEVER** hand-edit the lock — regenerate via `metaphor sync --update` and commit both together.
- **MUST** declare every hand-written, non-schema-derived file under `apps/<app>/metaphor.codegen.yaml` → `user_owned:`, and wrap hand edits inside generator files in `// <<< CUSTOM … // END CUSTOM` markers. Unlisted/unmarked changes are silently wiped by `metaphor schema generate --force`.
- **NEVER** copy files between apps — promote shared code to an upstream module.
- **MUST** declare every required runtime env var in the matching `.env.*.example` template (the example is the contract; stacks fail-fast on missing vars — no silent defaults).
- **MUST** use `{$VAR}` parse-time placeholders for Caddy site addresses, never `{env.VAR}`.
- **SHOULD** use `metaphor dev` / `metaphor test` / `metaphor build` over raw `cargo` / `gradle`.
- **MUST** run the chaos gate after business-flow-level changes (new/changed flow, cross-module seam, new external dependency, tenancy/RLS/auth, runtime infra) — see [`docs/chaos/README.md`](docs/chaos/README.md). Typos, cosmetics, docs-only, tests-only, and behavior-identical refactors are exempt.
- **MUST** read the target repo's own `CLAUDE.md` before working in any repo (each app, each module clone, sibling repos). The more-local `CLAUDE.md` always wins; don't carry assumptions across repo boundaries. Protocol: [`docs/agent/cross-repo.md`](docs/agent/cross-repo.md).

## Workspace shape

```
metaphor.yaml / metaphor.lock   # projects[] + resolved SHAs (check in together)
modules/                        # upstream clones — READ-ONLY (gitignored, rebuilt by sync)
apps/                           # __project__-service · __project__-webapp-* · __project__-mobile-provider
deployment/                     # compose.dev.yaml / compose.yaml, caddy/, observability, backups, chaos/ (fault kit)
docs/                           # runbooks + agent/ (dev playbook) + chaos/ (resilience gate)
metaphor.deploy.yaml            # envs (dev/uat/prod), services, image tags
```

## Load on demand — read before the matching task

| Read | Before |
|---|---|
| [`docs/agent/per-app.md`](docs/agent/per-app.md) | touching any app (types, stacks, ports, quirks) |
| [`docs/agent/tasks.md`](docs/agent/tasks.md) | common tasks (update upstream, add app, migrations, deploy) |
| [`docs/agent/anti-patterns.md`](docs/agent/anti-patterns.md) | writing code/config — the full list with consequences |
| [`docs/agent/cross-repo.md`](docs/agent/cross-repo.md) | crossing into the framework tree or sibling product repos |
| [`docs/chaos/README.md`](docs/chaos/README.md) | the chaos gate: criteria, catalog, how to run |
| [`docs/LOCAL-DEVELOPMENT.md`](docs/LOCAL-DEVELOPMENT.md) · [`docs/PRODUCTION-DEPLOYMENT.md`](docs/PRODUCTION-DEPLOYMENT.md) · [`docs/RELEASE-RUNBOOK.md`](docs/RELEASE-RUNBOOK.md) | running stacks / shipping |
| `metaphor.deploy.yaml`, `deployment/compose.*.yaml` | deploy / stack work |
| Skill `metaphor-cli-master` · `backbone-cli-master` · `modules-orchestrator` | CLI depth, Backbone workflows, module composition |
