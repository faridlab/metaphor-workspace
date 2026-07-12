# Release Runbook — Ship an Update to Prod

Step-by-step for shipping a code change to production. Read this every time until it's muscle memory.

For first-time VPS setup, see [VPS-HOSTINGER-SETUP.md](VPS-HOSTINGER-SETUP.md). For deeper background on `metaphor deploy` mechanics, see [UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md).

## TL;DR — the happy path

1. Commit + push your change in the inner app repo (`apps/<app>/`).
2. Tag it: `git tag v0.1.X -m 'version 0.1.X' && git push origin v0.1.X`.
3. Wait for the green checkmark in GitHub Actions (~5-10 min).
4. From the workspace root: `metaphor deploy push prod --tag v0.1.X --skip-build --skip-migrate --yes`.
5. If your change includes a DB migration, run it via SSH tunnel from your laptop (see [Step 5b](#step-5b--run-migrations-via-ssh-tunnel-if-needed)).
6. Verify: `curl https://api.__project__.com/health`.

**Total time: ~10-15 minutes.** Never build locally — see [Pitfall #1](#pitfall-1-never-run-metaphor-deploy-push-without---skip-build). Always `--skip-migrate` — see [Pitfall #6](#pitfall-6-metaphors-built-in-migrate-step-is-broken).

---

## One-time prereqs (do these once per laptop)

### 1. SSH config override for `__project__.com`

`__project__.com` DNS is proxied (Cloudflare-style), so port 22 doesn't pass through. SSH must go to the origin VPS IP. Append to `~/.ssh/config`:

```
Host __project__.com
    HostName 187.77.115.196
    User deploy
    IdentityFile ~/.ssh/id_rsa
```

Test:

```bash
ssh deploy@__project__.com 'echo ok && hostname'
# → ok / __project__-prod
```

Without this, `metaphor deploy` hangs at the scp/SSH step with `Operation timed out`.

### 2. GHCR docker login (only if you need to manually pull images)

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <your-gh-user> --password-stdin
```

PAT needs `read:packages` (and `write:packages` if you ever push manually, but CI handles pushes).

---

## Per-release steps

### Step 1 — Make and verify your change

In the relevant inner app repo:

```bash
cd apps/__project__-service     # or whichever app changed
# ...edit code, run tests locally...
git add .
git commit -m 'feat: …'
git push origin main
```

### Step 2 — Tag the release

```bash
git tag v0.1.X -m 'version 0.1.X'
git push origin v0.1.X
```

The tag triggers `.github/workflows/release.yml` in that inner repo. **Each app has its own workflow and its own version tag.**

| Inner repo | Workflow | Result |
|---|---|---|
| `apps/__project__-service` | release-service | `ghcr.io/faridlab/__project__-service:v0.1.X` |
| `apps/__project__-webapp-customer` | release-webapp-customer | `ghcr.io/faridlab/__project__-webapp-customer:v0.1.X` |
| `apps/__project__-webapp-provider` | release-webapp-provider | same pattern |
| `apps/__project__-webapp-admin` | release-webapp-admin | same pattern |
| `apps/__project__-webapp-download` | release-webapp-download | same pattern |

Only tag the repos that actually changed. Unchanged apps keep their current tag in `.env.prod`.

### Step 3 — Wait for CI

Open the inner repo's Actions tab (e.g. https://github.com/faridlab/__project__-service/actions) and wait for the green check. Build time:

- __project__-service: ~5-10 min (native amd64 on `ubuntu-latest`)
- webapps: ~3-5 min each

If the build fails: click in, read the log, fix on `main`, re-tag (delete + recreate the tag).

### Step 4 — Verify image is in GHCR

```bash
docker manifest inspect ghcr.io/faridlab/__project__-service:v0.1.X >/dev/null && echo "ok"
```

Or visually: https://github.com/faridlab?tab=packages.

### Step 5 — Deploy

From the **workspace root** (`__project__-metaphor/`):

```bash
metaphor deploy push prod --tag v0.1.X --skip-build --skip-migrate --yes
```

Two flags, both mandatory until upstream bugs are fixed:

- **`--skip-build`** — skips the local 4-hour QEMU build; VPS pulls the CI-built image instead.
- **`--skip-migrate`** — skips metaphor's in-container migration step, which is broken on this stack (distroless image has no shell + the in-process `__project__-service migrate` is a stub). Migrations are run separately in [Step 5b](#step-5b--run-migrations-via-ssh-tunnel-if-needed).

Pipeline:

1. Rewrites `*_TAG=v0.1.X` in `deployment/.env.prod` locally
2. `scp` it to `/srv/__project__/deployment/.env.prod` on the VPS
3. SSH: `docker compose pull` (fetches `:v0.1.X` from GHCR)
4. SSH: `docker compose up -d` (rolling restart)

Total: ~2 minutes.

### Step 5b — Run migrations via SSH tunnel (if needed)

Only do this if your release changed `modules/*/schema/migrations/`. For code-only changes (config tweaks, dep bumps, frontend rebuilds), skip to Step 6.

The in-container `__project__-service migrate` subcommand is a stub (see [apps/__project__-service/CLAUDE.md](../apps/__project__-service/CLAUDE.md)). Real migrations are run from your laptop via `metaphor migration run-all` against the prod DB through an SSH tunnel. This is the documented pattern — see [deployment/README.md](../deployment/README.md).

```bash
# 1. Open a tunnel from local 5433 → VPS host loopback 5432
#    (postgres is bound to 127.0.0.1:5432 on the VPS via commit 82da16d).
#    NOTE: do NOT use `5433:postgres:5432` — Docker DNS doesn't resolve
#    in the SSH host context; the connection drops mid-handshake.
ssh -N -L 5433:127.0.0.1:5432 deploy@__project__.com &
TUNNEL_PID=$!
sleep 1   # let the tunnel come up

# 2. Pull DB creds from deployment/.env.prod
source <(grep -E '^POSTGRES_(USER|PASSWORD|DB)=' deployment/.env.prod | sed 's/^/export /')

# 3. Run migrations against prod through the tunnel
DATABASE_URL="postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@127.0.0.1:5433/$POSTGRES_DB" \
  metaphor migration run-all

# 4. Tear down the tunnel
kill $TUNNEL_PID
```

Safety:

- Bind **only** to `127.0.0.1:5433` — never `0.0.0.0`.
- Never paste `deployment/.env.prod` contents anywhere.
- Confirm `metaphor migration run-all` shows "no pending migrations" if you didn't expect any — that tells you nothing's about to silently alter the schema.

When `MigrationManager` is replaced with a real in-process runner upstream, this whole step goes away and metaphor's built-in `migrate` step can be re-enabled (drop `--skip-migrate`). Until then: this is the truth.

### Step 6 — Verify prod is healthy

```bash
curl -fsS https://api.__project__.com/health     # → 200 OK
metaphor deploy status prod                   # all services "Up"
metaphor deploy logs prod --service __project__-service --follow   # tail for 30s, look for errors
```

Open the webapps in a browser to confirm a real user request works end-to-end.

---

## Mixed-tag deploys (only some apps changed)

`metaphor deploy push --tag X` applies the **same tag to every service**, which fails if you didn't bump them all. Two options:

### Option A — single-service deploy (recommended)

Use `metaphor deploy service <env> <service> <tag>` — bumps one service's `*_TAG`, pulls and restarts only that container, and **records the deploy in history**:

```bash
metaphor deploy service prod __project__-service v0.1.X
```

The image must already be in the registry (e.g. just built by CI). No build, no migrate. Other services keep running on their existing tags. The `*_TAG` env var is derived automatically from the service name (`tag_env` in `metaphor.deploy.yaml`), so you don't pass it.

To stage a tag change for review/commit **before** deploying (no SSH, no deploy), bump it locally first:

```bash
metaphor deploy bump prod --service __project__-service --tag v0.1.X   # edits deployment/.env.prod only
git diff deployment/.env.prod                                       # review
# ...commit, then `metaphor deploy service prod __project__-service v0.1.X`
```

### Option B — hand-edit `.env.prod` then push

```bash
# Edit deployment/.env.prod so each *_TAG points at the right version per service.
# Then push WITHOUT --tag (it reads what's already in the file):
metaphor deploy push prod --skip-build --yes
```

---

## Rollback

All historical images stay in GHCR. Rolling back = pointing the env file at an older tag.

### Quick rollback (one step back)

```bash
metaphor deploy rollback prod --yes
```

Reads `deployment/history/prod.jsonl`, picks the previous successful tag, scp's new env, pulls, restarts. ~30 seconds.

### Explicit tag rollback

```bash
metaphor deploy rollback prod --to v0.1.X --yes
```

Bypasses history. Image must still exist in GHCR — it does, unless you manually deleted packages.

### What rollback does NOT do

- **Does not revert migrations.** If the bad release shipped a destructive schema change, you need a *forward-fix* migration to restore compatibility, then roll back the code. See [UPDATING-DEPLOYMENTS.md § Migration rollback](UPDATING-DEPLOYMENTS.md#migration-rollback-rare).
- **Does not preserve in-flight requests.** Compose `up -d` recreates containers — expect ~5s of dropped traffic.

---

## Pitfalls (each cost real time at least once)

### Pitfall 1 — Never run `metaphor deploy push` without `--skip-build`

Bare `metaphor deploy push prod` rebuilds **all** images locally. On an Apple Silicon Mac, that means `docker buildx --platform linux/amd64` → QEMU x86 emulation → 4+ hours for the Rust service alone. **Always go via CI tags + `--skip-build`.**

If you genuinely need to build locally (CI is down, hotfix that can't wait): expect 3-5 hours and start now. Don't fight it mid-build.

### Pitfall 2 — Tag must be on a commit that contains the workflow file

GitHub Actions reads `.github/workflows/release.yml` **from the commit being built**, not from the branch tip. If your tag points at a commit older than when the workflow was added, no run fires.

Check:

```bash
git show v0.1.X -- .github/workflows/release.yml | head
# empty output → workflow file not present at that tag
```

Fix: delete and re-tag from a commit that contains the workflow:

```bash
git tag -d v0.1.X
git push origin :refs/tags/v0.1.X
git checkout main && git pull
git tag v0.1.X -m 'version 0.1.X'
git push origin v0.1.X
```

### Pitfall 3 — SSH timeout to `__project__.com`

If `metaphor deploy push --skip-build` hangs at `Operation timed out`, the cause is almost always one of:

1. **Missing ssh_config override** — see [prereq #1](#1-ssh-config-override-for-__project__com). Confirm with `ssh deploy@__project__.com 'echo ok'`.
2. **fail2ban banned your IP** — too many failed SSH attempts. Default ban is 10 min. Either wait, or unban via Hostinger's browser-terminal:
   ```bash
   fail2ban-client unban --all
   ```
3. **Your network blocks outbound port 22** — some corporate / hotel networks do. Tether to your phone to confirm; if so, use a different network.

Distinguish "VPS down" from "SSH-only blocked":

```bash
ping -c 2 __project__.com           # ICMP — VPS reachable?
curl -fsS https://__project__.com   # web works → VPS up, app running
nc -zv __project__.com 22           # SSH port specifically
```

If ping/curl work but `nc 22` times out → SSH/firewall issue, NOT VPS issue.

### Pitfall 4 — UAT webapp images don't exist (yet)

The webapp release workflows currently bake `VITE_API_BASE_URL=https://api.__project__.com` (prod only). UAT-variant builds are a planned follow-up — for now, only prod is shipped via CI. Don't try to `metaphor deploy push uat --tag v0.1.X --skip-build` for webapps until UAT-variant CI exists.

The service workflow is env-agnostic — UAT can pull the same `__project__-service:v0.1.X` image.

### Pitfall 5 — Hand-edited `.env.prod` overwritten by `metaphor deploy`

`metaphor deploy push --tag X` rewrites every `*_TAG` line. If you carefully set mixed versions by hand and then run a `--tag` push, your changes are wiped. Use [Option B](#option-b--hand-edit-envprod-then-push) above (push without `--tag`) or `metaphor deploy service <env> <svc> <tag>` for per-service updates.

### Pitfall 6 — metaphor's built-in migrate step is broken

`metaphor deploy push` ends with an in-container migration step that **does not work** on this stack. Three problems compounded:

1. **Doubled subcommand** — metaphor templates `docker compose run run --rm migrations …` (note `run run`). The second `run` is parsed as a service name → "no such service: run".
2. **Distroless image has no shell** — even with the syntax fixed, metaphor wraps the command in `sh -lc "…"`. The runtime base is [`gcr.io/distroless/cc-debian12`](../apps/__project__-service/Dockerfile#L54): no `sh`, no busybox. The arguments are appended to the binary's `ENTRYPOINT` instead, so the service sees `sh` as the first arg and dies with `unknown subcommand 'sh'`.
3. **`__project__-service migrate` is a stub** — per [apps/__project__-service/CLAUDE.md](../apps/__project__-service/CLAUDE.md), the in-process `backbone_orm::migrations::MigrationManager` is not yet implemented. Even with a real shell and correct invocation, the subcommand wouldn't apply anything.

**Workaround**: always pass `--skip-migrate` to `metaphor deploy push`, then run migrations via SSH tunnel ([Step 5b](#step-5b--run-migrations-via-ssh-tunnel-if-needed)). Don't try to invoke the in-container migration manually — it's a stub regardless of how you call it.

When `MigrationManager` is replaced upstream and metaphor stops templating `sh -lc` / `run run`, this pitfall (and Step 5b) collapses back to a single `metaphor deploy push` call.

---

## Reference

- [metaphor.deploy.yaml](../metaphor.deploy.yaml) — env definitions (dev/uat/prod), per-app image config
- [deployment/.env.prod](../deployment/.env.prod) — actual tags currently deployed (gitignored on disk; example at `.env.prod.example`)
- [deployment/history/prod.jsonl](../deployment/history/) — append-only deploy log (used by rollback)
- `metaphor deploy preflight prod` — validate env files before deploying (contract vars + `docker compose config`)
- `metaphor deploy service <env> <svc> <tag>` — single-service deploy (records history); `metaphor deploy bump <env> --service <svc> --tag <tag>` to only stage the local tag change
- [DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md) — full `metaphor deploy` flag reference
- [UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md) — longer-form deploy concepts (expand/contract migrations, etc.)
