# Common tasks — recipes

Recipes for recurring work in a Metaphor consumer workspace. The chaos gate
lives in [`docs/chaos/README.md`](../chaos/README.md); per-app specifics in
[`per-app.md`](per-app.md); stack operation in
[`../LOCAL-DEVELOPMENT.md`](../LOCAL-DEVELOPMENT.md).

## Update to newer upstream

1. Edit the module's `ref:` in `metaphor.yaml` (tag or commit SHA).
2. `metaphor sync --update` — resolves and writes `metaphor.lock`, syncs `modules/`.
3. `metaphor migration run-all` — bring DBs up to date.
4. `metaphor test --affected` — test only what the bump touched.
5. Commit `metaphor.yaml` + `metaphor.lock` **together** (lock drift is an
   anti-pattern).

Gotcha: `sync --update` invalidates every cargo fingerprint — expect a long
rebuild, and never run host and container builds in parallel afterwards.

## Add a new app

`metaphor apps generate <name> --type <backend-service|mobileapp|webapp|…>` —
wires the project into `metaphor.yaml` automatically, then give it a
`CLAUDE.md` via `metaphor agent claude init`. Declare its hand-written files
under `apps/<app>/metaphor.codegen.yaml` → `user_owned:` immediately.

## Add a new domain module

`metaphor module create <name>` clones the module skeleton. Add the module
to `metaphor.yaml` (or let the command do it), then `metaphor sync` and
`metaphor migration run-all`. If your stack uses RLS/app roles, follow the
workspace's post-migration grant step after CLI-applied migrations.

## Run migrations across all DBs

`metaphor migration run-all`. The dev compose does not run migrations
automatically. Judge fresh-DB runs by object existence (e.g.
`to_regclass`), not exit codes — apps without migrations always "fail".

## Test only what changed

`metaphor test --affected --base=main`. Live HTTP probes must target the
explicit `127.0.0.1` address (see
[anti-patterns](anti-patterns.md)).

## Bring up the local dev stack

`metaphor docker up --env dev` — data stores + backend with hot reload;
frontends on the host via `pnpm dev` by default. Never run the dev and prod
compose files at once — they collide on `127.0.0.1:5432`.

## Run the chaos gate

Required after business-flow-level changes (criteria in
[`docs/chaos/README.md` §2](../chaos/README.md)). Work through the catalog
experiments the doc defines; never run the gate while someone else is using
the stack.

## Deploy to prod

1. `metaphor deploy preflight prod` — validates env, secrets, image tags.
2. Single service: `metaphor deploy service prod <service> <tag>`; full
   stack: `metaphor deploy push prod` (flags per
   [../DEPLOY-COMMANDS.md](../DEPLOY-COMMANDS.md)).
3. Runbooks: [../PRODUCTION-DEPLOYMENT.md](../PRODUCTION-DEPLOYMENT.md),
   [../UPDATING-DEPLOYMENTS.md](../UPDATING-DEPLOYMENTS.md),
   [../RELEASE-RUNBOOK.md](../RELEASE-RUNBOOK.md).

## Bump a service image tag

`metaphor deploy bump prod --service <service> --tag <tag>` — writes `*_TAG`
to the **local** `.env.prod` only. Review, commit, then deploy.

## Reclaim disk after finished work

Delete module/app `target/` dirs and `docker builder prune --all`. While a
dev container runs, KEEP the cargo volumes (deleting them costs a long cold
rebuild) and never delete a host `target/` under a live cargo-watch.

## Refresh the Claude Code setup

`metaphor agent claude update` — re-applies the CLAUDE.md templates. Edits
made to stamped files that should survive belong in the workspace's own
copies or in the upstream template pack.
