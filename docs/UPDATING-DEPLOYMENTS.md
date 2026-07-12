# Updating Deployments

How to ship a new release to an existing deployment, promote uat→prod, run migrations between deploys, and roll back when something goes wrong.

For first-time deploy (fresh VPS, day-1 setup), see [PRODUCTION-DEPLOYMENT.md](PRODUCTION-DEPLOYMENT.md). For `metaphor deploy` flag details, see [DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md).

## The release loop

The standard flow when shipping a code change to production:

```
┌─────────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ develop     │ ──► │ land on  │ ──► │ push UAT │ ──► │ verify   │ ──► │ promote  │
│ locally     │     │  main    │     │          │     │  on UAT  │     │ to prod  │
└─────────────┘     └──────────┘     └──────────┘     └──────────┘     └──────────┘
```

Concrete commands:

```bash
# 1. Develop locally
metaphor docker up --env dev --build
# (make changes, run tests)
metaphor test --affected --base=main

# 2. Land on main
git push origin <branch> && open a PR; merge after review.
git checkout main && git pull

# 3. Push to UAT first
metaphor deploy push uat

# 4. Verify on UAT
metaphor deploy status uat
metaphor deploy logs uat --follow --service __project__-service
curl https://api.uat.__project__.com/health
# Run smoke tests against the UAT URLs

# 5. Promote to prod (reuse the UAT-built images — no rebuild)
SHA=$(git rev-parse --short HEAD)
metaphor deploy push prod --tag $SHA --skip-build --yes

# 6. Verify prod
metaphor deploy status prod
curl https://api.__project__.com/health
```

## Image promotion (reuse over rebuild)

`--skip-build` is important. When you promote uat→prod with the **same tag** that was just verified on UAT, you're shipping a **byte-identical image** to prod — no surprises from a rebuild.

Without `--skip-build`, you'd build fresh images and push them under the same tag, which:

- Wastes build time
- Could pull in different upstream apt/cargo registry state if you build hours apart
- Makes the prod artifact different from what you tested on UAT

**Rule of thumb**: build once at UAT push time, promote with `--skip-build` after.

## Migration handling

By default, `metaphor deploy push` runs migrations after `compose up -d`. The migrate command is set in [`metaphor.deploy.yaml`](../metaphor.deploy.yaml) under `defaults.migrate_command` (defaults to `metaphor migration run-all`).

### Default flow (auto-migrate)

```bash
metaphor deploy push uat        # builds → ssh up -d → migrate
```

Fine for additive schema changes (new tables, new columns with defaults).

### Explicit migrate-then-deploy

For schema-breaking changes, control the order:

```bash
metaphor deploy migrate uat                       # run migrations first
metaphor deploy push uat --skip-migrate           # then push code (skip auto-migrate)
```

### Expand/contract for breaking changes

When a column rename or table restructure can't be done atomically:

1. **Expand** — deploy a migration that adds the new shape *alongside* the old (new column, both writable)
2. **Migrate code** — deploy code that writes to both shapes, reads from the new
3. **Backfill** — copy data from old to new
4. **Contract** — deploy a migration that drops the old shape

Each step is its own `metaphor deploy push` with `--skip-migrate` until the schema-only step. This is advanced; consult the upstream backbone docs before attempting.

## Rollback

The 2 a.m. section. `metaphor deploy` keeps an append-only log of every push and rollback in [`deployment/history/<env>.jsonl`](../deployment/history/) plus an env-file snapshot per deploy, so you don't have to look up SHAs by hand.

```bash
# 1. (Optional) confirm what's deployed and what was before
metaphor deploy history prod --limit 5

# 2. Roll back to the previous successful deploy (default: 1 step back)
metaphor deploy rollback prod
metaphor deploy rollback prod --yes        # non-interactive

# Or N successful pushes back, skipping any failed ones in between:
metaphor deploy rollback prod --steps 2

# Or explicit tag (bypasses history):
metaphor deploy rollback prod --to <previous-sha> --yes

# 3. Verify
metaphor deploy status prod
curl https://api.__project__.com/health
```

`rollback` does steps 4-7 of `push` (rewrite env file tags, scp, pull, up -d) **without** rebuilding. The previous tag must already exist in the registry — that's why `--skip-build` promotion is preferred over rebuilds: the old artifact is still there to roll back to.

The rollback itself is recorded in the history (with `action: rollback` and the source tag), so subsequent `--steps` counts continue to make sense.

### What rollback does NOT do

- **Does not revert migrations.** Image rollback flips the application code; the database schema is whatever the latest forward-migration left it as. If the bad release shipped a destructive migration, you need a *forward-fix* migration that restores compatibility, then rollback the code.
- **Does not preserve in-flight requests.** Compose `up -d` restarts containers; expect a brief drop.

### Migration rollback (rare)

There's no automated mechanism. The pattern:

1. Roll back code first: `metaphor deploy rollback prod --to <safe-sha>`
2. Write a *forward* migration that undoes the bad schema change
3. Apply it via `metaphor migration run-all` (locally, against prod over a tunnel — see [deployment/README.md](../deployment/README.md))
4. Move on; treat the original migration's SHA as deprecated

## Deployment history

Every successful `push` and `rollback` writes a JSONL record to
[`deployment/history/<env>.jsonl`](../deployment/history/) and snapshots the
env file used for the deploy under `deployment/history/snapshots/`. Both are
mirrored to `<deploy_dir>/history/` on the remote host.

```bash
# Last 20 deploys for prod
metaphor deploy history prod

# Read from the production VPS instead of the local workspace
metaphor deploy history prod --remote

# JSON for scripting
metaphor deploy history prod --json
```

Sample output:

```
TIMESTAMP (UTC)       ACTION    TAG         OK   DEPLOYER
2026-04-25 14:02:00   push      abc1234     ✓    farid@laptop
2026-04-25 11:30:00   push      def5678     ✓    farid@laptop
2026-04-24 09:15:00   push      aaa1111     ✗    farid@laptop
    error: ssh exited 255: Connection refused
2026-04-23 18:00:00   rollback  bbb2222     ✓    ops@vps
```

**Permanent record.** History is never auto-pruned. Commit `deployment/history/` to git so it survives a wiped laptop and so any team member can audit the deploy timeline.

**Concurrent pushes.** The local file is the source of truth and the remote is a best-effort mirror. If two operators push from separate laptops without pulling, the second push will overwrite the remote mirror with their local-only history. The fix is the same as for code: `git pull` before `metaphor deploy push`.

## Monitoring during/after rollout

```bash
# Tail logs as the rollout proceeds
metaphor deploy logs prod --service __project__-service --follow

# Compose health snapshot
metaphor deploy status prod
```

For metrics + dashboards, log into Grafana at `https://grafana.__project__.com/` and watch:

- **golden-signals** dashboard — request rate, error rate, latency p50/p95/p99
- **postgres-health** dashboard — connections, slow queries
- **host-resources** dashboard — CPU, memory, disk

Setup details and alerting rules: [deployment/README.md](../deployment/README.md).

## Common scenarios

### Backend-only change, no schema migration

```bash
metaphor deploy push uat
# verify, then promote
metaphor deploy push prod --tag $(git rev-parse --short HEAD) --skip-build --yes
```

### Frontend-only change

`metaphor deploy push` rebuilds and rolls out all images. To touch only one frontend, build/push just its image, then roll out only that service with `metaphor deploy service` (which updates only that `*_TAG`, pulls + restarts only that container, and records history):

```bash
SHA=$(git rev-parse --short HEAD)

docker buildx build --platform linux/amd64 \
  --build-arg VITE_API_BASE_URL=https://api.uat.__project__.com \
  -t ghcr.io/faridlab/__project__-webapp-provider:$SHA --push apps/__project__-webapp-provider

# Roll out just this service (no build, no migrate, no other service touched)
metaphor deploy service uat __project__-webapp-provider $SHA
```

If CI already built the image (tagged release), skip the `docker buildx` step and go straight to `metaphor deploy service`.

### Image-only promotion uat→prod

```bash
SHA=$(git rev-parse --short HEAD)
metaphor deploy push prod --tag $SHA --skip-build --yes
```

The UAT images at `:$SHA` already exist in GHCR; this flips prod to point at them. **No rebuild, no surprises.**

### Hotfix to prod, skip UAT

Only when prod is broken and UAT can't catch up in time. **Always** `--dry-run` first:

```bash
metaphor deploy push prod --dry-run
metaphor deploy push prod
```

Make a UAT push afterwards to keep environments in sync.

### Roll back a bad release

See the [Rollback](#rollback) section above.

## Known limitations

- **No zero-downtime deploys.** Single-VPS docker compose; `up -d` recreates containers, causing a brief drop (~5s). For SLA-sensitive deployments, blue/green or rolling restart at a higher orchestration tier is needed (out of scope for the beta architecture; see [DEPLOYMENT-PLAN.md](DEPLOYMENT-PLAN.md)).
- **Migrations not auto-rolled-back.** Schema reverts must be forward-fix migrations (see above).
- **Webapp/admin builds bake `VITE_API_BASE_URL` at build time.** Changing the API URL for an environment requires a rebuild — set it in [`metaphor.deploy.yaml`](../metaphor.deploy.yaml) `environments.<env>.images.<name>.build_args.VITE_API_BASE_URL`. The variable is consumed by Vite at build time and frozen into the bundle.
- **`metaphor deploy push` always builds and rolls out all images.** For a single service, use `metaphor deploy service <env> <svc> <tag>` (pulls + restarts only that container from a pre-built registry image; records history).

## See also

- [DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md) — full `metaphor deploy` flag reference (push, rollback, status, logs, migrate, exec)
- [PRODUCTION-DEPLOYMENT.md](PRODUCTION-DEPLOYMENT.md) — first-time deploy walkthrough
- [deployment/README.md](../deployment/README.md) — VPS-side runbook (backups, restore, monitoring)
- [DEPLOYMENT-PLAN.md](DEPLOYMENT-PLAN.md) — architecture rationale and roadmap
- [metaphor.deploy.yaml](../metaphor.deploy.yaml) — env definitions for `dev`, `uat`, `prod`
