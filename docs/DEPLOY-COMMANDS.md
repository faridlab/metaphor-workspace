# `metaphor docker` and `metaphor deploy`

Two command families in the `metaphor-dev` plugin (surfaced as top-level
commands by `metaphor`) drive containerised deployments from a single
config file.

- `metaphor docker …` — local `docker compose` lifecycle (dev machine)
- `metaphor deploy …` — remote push/rollback/status over SSH (UAT, prod)

Both read [`metaphor.deploy.yaml`](../metaphor.deploy.yaml) at the workspace
root. Environments with `host:` are remote; those without are local.

## Prerequisites

- `metaphor` binary on PATH (core CLI dispatches to the right plugin)
- `metaphor-dev` plugin installed (`metaphor plugin add metaphor-dev@latest`)
- `docker` and `docker compose` available
- For `deploy push`: `docker buildx`, `ssh`, `scp`, plus `git` (used to derive
  the default tag when `--tag` is omitted)
- For remote envs: key-based SSH access to the target host and a reachable
  deploy directory (`/srv/__project__` by default)

## Local — `metaphor docker`

Operates on the local compose file + env file for a given local environment
(default `dev`).

```bash
metaphor docker up                           # detached, no rebuild
metaphor docker up --build                   # rebuild first
metaphor docker up --service __project__-service
metaphor docker down
metaphor docker down --volumes               # destructive: wipes pgdata etc.
metaphor docker logs --follow --service __project__-service
metaphor docker ps
metaphor docker restart --service __project__-service
metaphor docker pull
metaphor docker build --push
```

`--env <name>` selects a non-default local environment (e.g. a lightweight
profile). Errors out if the named environment has `host:` — that's a remote
target, use `deploy` instead.

## Remote — `metaphor deploy`

Each subcommand takes a positional environment name.

```bash
metaphor deploy push uat                     # full build + push + roll out
metaphor deploy push prod --dry-run          # print commands only
metaphor deploy push uat --tag abc1234       # pin a specific tag
metaphor deploy push uat --skip-build        # reuse registry images
metaphor deploy push uat --skip-migrate      # skip the migrate step
metaphor deploy push prod --yes              # skip confirmation

metaphor deploy rollback prod                       # 1 step back (default)
metaphor deploy rollback prod --steps 2             # 2 successful pushes back
metaphor deploy rollback prod --to e1f4a2c --yes    # explicit tag

metaphor deploy history prod                        # last 20 deploys
metaphor deploy history prod --limit 5              # last 5
metaphor deploy history prod --remote               # read from VPS
metaphor deploy history prod --json                 # for scripting

metaphor deploy status uat
metaphor deploy logs uat --service __project__-service --follow
metaphor deploy migrate uat

# Single-service / validation (replace the old scripts/*.sh)
metaphor deploy preflight prod                                  # validate local env files before a push
metaphor deploy service prod __project__-webapp-download v0.1.2    # deploy ONE pre-built service; records history
metaphor deploy bump prod --service __project__-service --tag v0.5.2   # stage a *_TAG change locally (no SSH, no deploy)
```

`deploy service` is the per-service path: it bumps only that service's `*_TAG`,
pulls + `up -d` + `ps` only that container, and records history — no build, no
migrate (the image must already be in the registry). The `*_TAG` env var is
derived from the service name via `images.<svc>.tag_env`. `deploy preflight`
validates each service's `<context>/.env.prod` against its `.env.prod.example`
contract and runs `docker compose config`. `deploy bump` only edits the local
env file so you can review the diff and commit before deploying.

Every successful `push` and `rollback` is recorded in
`deployment/history/<env>.jsonl` and mirrored to `<deploy_dir>/history/` on
the remote host. The env file used for each deploy is snapshotted under
`deployment/history/snapshots/.env.<env>.<timestamp>-<sha>` for audit.
History is **never auto-pruned** — commit `deployment/history/` to git for
a permanent record across machines.

### What `push` actually does

1. Resolves the target environment and tag (short git SHA unless `--tag` given).
2. For each image under `environments.<env>.images`:
   - `docker buildx build --platform linux/amd64 --push -t <registry>/<name>:<tag>`
   - Applies `build_args` and uses `context` as the build root.
3. Updates `<tag_env>=<sha>` entries in the local env file (e.g. `SERVICE_TAG=abc1234`).
4. `scp` env file → `<ssh_user>@<host>:<deploy_dir>/<env_file>`.
5. SSH to host → `docker compose -f <compose> --env-file <env> pull`.
6. SSH to host → `docker compose -f <compose> --env-file <env> up -d`.
7. Runs `migrate_command` via `docker compose run --rm migrations …` (unless
   `--skip-migrate`).
8. **Records the deploy** in `deployment/history/<env>.jsonl`, snapshots the
   env file under `deployment/history/snapshots/`, and mirrors both to the
   remote host's `<deploy_dir>/history/`. A failed push still gets recorded
   (with `status: failed`) so `rollback` can step over it.

Intentionally thin. No service discovery, no bespoke orchestration layer —
just `docker buildx`, `scp`, `ssh`, `docker compose`, and an append-only log.

### Confirmation gate

Any environment with `require_confirm: true` (typically `prod`) prompts before
pushing. Use `--yes` to bypass in scripted contexts.

## Config: `metaphor.deploy.yaml`

Minimal shape:

```yaml
version: 1
defaults:
  registry: ghcr.io/your-org
  compose_file: deployment/compose.yaml
  ssh_user: deploy
  deploy_dir: /srv/app
environments:
  dev:
    env_file: deployment/.env.dev
    images:
      api:
        context: apps/api
        tag_env: SERVICE_TAG
  prod:
    host: prod.example.com
    env_file: deployment/.env.prod
    require_confirm: true
    images:
      api:
        context: apps/api
        tag_env: SERVICE_TAG
```

See [`deploy_config.rs`](../../../frameworks/metaphora/metaphor-plugin-dev/src/deploy_config.rs)
for the full field set.

## Legacy infra-script deploys

Projects that already have an `infra/deploy.sh` (or `infra/Makefile`) can use:

```bash
metaphor deploy exec [--infra <name>] [-- args...]
```

This is the migration path from the previous native `metaphor deploy` command,
which ran `./deploy.sh` from the workspace's `infra` project. It does **not**
read `metaphor.deploy.yaml`; it only consults `metaphor.yaml` to find the
infra project. See [`docs/commands/deploy.md`](../../../frameworks/metaphora/metaphor-plugin-dev/docs/commands/deploy.md#deploy-exec)
in the plugin repo for details.
