# metaphor-workspace

A **template consumer workspace** for building a product on the [Metaphor](https://github.com/faridlab/metaphor-cli)
framework. Clone it, rename `__project__` → your product name, and you have a working multi-app workspace with
the base framework modules pinned, a single-VPS Docker deployment stack, and the ops runbooks already wired.

This repo is a **consumer workspace** (not a framework repo): upstream framework crates and domain modules are
pinned by `remote:` + `ref:` in [`metaphor.yaml`](metaphor.yaml), resolved to commit SHAs in `metaphor.lock`,
and synced into `modules/` (read-only) by `metaphor sync`. Your application code lives in `apps/`.

## Start a new product from this template

```bash
# 1. get the template
git clone git@github.com:faridlab/metaphor-workspace.git myproduct && cd myproduct
rm -rf .git && git init                      # start your own history

# 2. rename the placeholder (__project__ / __PROJECT__) to your product name, everywhere
grep -rl '__project__\|__PROJECT__' . | xargs sed -i '' 's/__project__/myproduct/g; s/__PROJECT__/Myproduct/g'

# 3. pull the pinned framework modules + add your own
metaphor sync                                # clone/update modules/ to the pinned refs in metaphor.yaml
metaphor doctor                              # tooling + upstream health
metaphor module create myproduct-catalog     # scaffold a domain module (clones the module skeleton)
metaphor apps generate myproduct-service     # scaffold a backend-service app

# 4. run it
metaphor migration run-all                   # bring DBs up to date
metaphor dev serve                           # run the current app
```

## What's in the template

| Path | What |
|---|---|
| `metaphor.yaml` | The manifest — base framework modules (`backbone-framework`/`sapiens`/`bucket`) pinned by ref + one example `__project__-service` app. Add your modules/apps here. |
| `metaphor.deploy.yaml` | Deployment topology (which apps deploy where). |
| `CLAUDE.md` | Orients Claude Code to the consumer-workspace conventions. |
| `deployment/` | A ready single-VPS Docker stack: `compose.yaml` + Caddy (TLS/reverse-proxy) + Grafana/Loki/Prometheus/Promtail (observability) + Postgres backups (restic). Customize the `__project__` service/DB names. |
| `docs/` | Ops runbooks — local dev, production deployment, release runbook, VPS setup, updating deployments. |
| `.gitignore` | Ignores `/modules` (synced, not committed), `.claude/` (installed via `metaphor agent install`), and deployment secrets. |

## Conventions

- **Modules are pinned, not vendored.** `modules/` is git-ignored; `metaphor sync` reconstructs it from
  `metaphor.yaml` + `metaphor.lock`. Never edit a synced module in place — change its `ref:` and re-sync.
- **Apps live in `apps/`** and consume modules via path/git dependency; each app is its own project.
- **`__project__` / `__PROJECT__`** are the placeholders to replace on clone (lowercase for identifiers —
  service/DB/container names; capitalized for prose/titles).
- Prefer `metaphor <cmd>` over raw `cargo`/`docker`/`git` when a subcommand exists (see `metaphor --help`).

> Derived from a real production workspace; the deployment stack and runbooks are battle-tested — only the
> product-specific names were replaced with `__project__` placeholders.
