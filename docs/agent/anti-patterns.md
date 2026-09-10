# Anti-patterns — the long list

Each entry states the mistake and its consequence once. The workspace
`CLAUDE.md` carries only the short MUST/NEVER core.

## Upstream / modules

- **Editing `modules/*` in place** — changes are wiped by the next
  `metaphor sync`. Fix the upstream repo, tag, re-pin, re-sync.
- **Running `cargo build` inside `modules/*`** — pollutes the upstream
  working tree. Use `metaphor build` (builds in the right place).
- **Committing `metaphor.lock` without the matching `metaphor.yaml` change**
  (or hand-editing the lock) — lock drift. Regenerate via
  `metaphor sync --update` and commit both together.

## Codegen safety

- **Adding a hand-written file inside a generator-owned tree**
  (`src/application/service/`, `src/domain/entity/`, `migrations/`, …)
  without listing it under `user_owned:` in `metaphor.codegen.yaml` — the
  next `metaphor schema generate --force` silently deletes it.
- **Hand-editing a generator-emitted file outside `// <<< CUSTOM …
  // END CUSTOM` markers** — edits are clobbered on regen. Wrap them, or
  list the whole file under `user_owned:`.
- **A hand-maintained migration that still carries the generator header** —
  it gets swept by `--force`. Remove the marker, move it to the manual
  migrations dir, or pin its path under `user_owned:`.
- **Copy-pasting code between apps** — creates drift. Promote shared code to
  an upstream module instead.

## Environments / compose

- **Running the dev and prod compose files simultaneously** — both bind
  `127.0.0.1:5432` and collide. Pick one.
- **Adding a Caddy site block with `{env.VAR}` for the host portion** —
  Caddy resolves site addresses at parse time; use `{$VAR}` or TLS
  provisioning fails.
- **Hand-editing `.env.prod` on the VPS without updating `.env.prod.example`
  in git** — the example is the contract; required vars are enforced at
  startup.
- **Deleting the cargo volumes while a dev container runs** — a long cold
  rebuild. Chaos experiments may only stop/start/recreate services, never
  volumes.
- **Running host and container Vite for the same webapp** — they fight over
  the dev-server port.

## Probing / testing

- **Probing `http://localhost:<port>`** — on many macOS hosts `localhost`
  resolves to `::1` first while the stack binds `127.0.0.1` only, and
  probes skip-false-pass. Always use the explicit `127.0.0.1` address.
- **Trusting a piped command's exit code** (`cargo test | tail` reports
  tail's status) — redirect to a file and read the real `$?`, or use
  PIPESTATUS.
- **Running stateful test harnesses concurrently** — shared fixtures sweep
  each other's state. Serialize them.

## Docs / process

- **Session jargon in commit messages, code comments, or docs** ("sprint 3",
  "ticket-42 done", pass/matrix counts) — write generic, self-contained
  language a reader next year still understands.
- **`source <(cmd)` in dev scripts on stock macOS bash 3.2** — silently
  delivers nothing. Use `eval "$(cmd | sed 's/^/export /')"`.
