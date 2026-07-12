# Production Deployment (First Time)

How to deploy __project__ to production for the first time on a fresh VPS.

This is the day-1 walkthrough. For the iterative release cycle (subsequent deploys, rollbacks, promotions), see [UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md). For why the architecture looks the way it does (single VPS, three networks, Caddy + observability), see [DEPLOYMENT-PLAN.md](DEPLOYMENT-PLAN.md).

## What you'll do

1. Make sure the VPS is provisioned and DNS is set
2. Populate `deployment/.env.prod` with secrets
3. Bootstrap `/srv/__project__/` on the VPS (one-time rsync of compose file + supporting dirs)
4. Run `metaphor deploy push prod`
5. Verify the deployment is healthy

Total time: ~30 minutes assuming no surprises.

## Prerequisites

### On the VPS

The VPS must already be provisioned per [DEPLOYMENT-PLAN.md](DEPLOYMENT-PLAN.md):

- Docker + Docker Compose v2 installed
- A non-root `deploy` user that's in the `docker` group and has SSH key access from your laptop
- Firewall open on `:80`, `:443` (Caddy auto-TLS) and your SSH port
- DNS A/AAAA records pointing all __project__ subdomains (`api.`, `app.`, `admin.`, `grafana.`, `bucket.`, `s3.`, `invoice.`, `status.`, `grpc.`) to the VPS IP
- A read-only GHCR Personal Access Token logged in via `docker login ghcr.io` (so the VPS can pull private images)

### On your laptop

- `metaphor` CLI on PATH + `metaphor-dev` plugin (`metaphor plugin add metaphor-dev@latest`)
- `docker buildx` (for multi-arch builds — __PROJECT__ builds `linux/amd64` even from Apple Silicon laptops)
- `ssh` and `scp` configured to reach the VPS
- `git` (used to derive the default tag from `HEAD`)
- This repo cloned locally; `metaphor sync` already run

### Configuration

```bash
# 1. Populate the prod env file
cp deployment/.env.prod.example deployment/.env.prod
chmod 600 deployment/.env.prod
$EDITOR deployment/.env.prod

# 2. Validate before deploying — catches missing required vars locally
#    instead of mid-deploy on the VPS.
metaphor deploy preflight prod
```

Set strong values for:

- `POSTGRES_PASSWORD` — long random string
- `JWT_HS256_SECRET` — 32+ char cryptographically random
- `MINIO_ROOT_PASSWORD` — long random string
- `GRAFANA_ADMIN_PASSWORD` — long random string
- `DOMAIN` — your real apex (e.g. `__project__.com`)
- `ACME_EMAIL` — a real address that Let's Encrypt notifications can reach

The `*_TAG` variables (`SERVICE_TAG`, `WEBAPP_CUSTOMER_TAG`, `WEBAPP_PROVIDER_TAG`, `WEBAPP_ADMIN_TAG`, `WEBAPP_DOWNLOAD_TAG`) will be filled in automatically by `metaphor deploy push` — leave them at `beta` or any placeholder for now.

```bash
# 2. Verify the prod environment is configured in metaphor.deploy.yaml
grep -A5 'prod:' metaphor.deploy.yaml
```

You should see:

```yaml
prod:
  host: __project__.com                        # adjust to your VPS hostname
  env_file: deployment/.env.prod
  require_confirm: true                     # interactive y/N before pushing
```

If `host:` doesn't match your VPS, update it. The `deploy_dir` defaults to `/srv/__project__` (set in `defaults.deploy_dir`); change at the workspace level if you've put the deploy elsewhere.

## The deploy command

```bash
metaphor deploy push prod                                       # interactive
metaphor deploy push prod --dry-run                             # print every command, don't execute
metaphor deploy push prod --tag $(git rev-parse --short HEAD) --yes   # non-interactive (CI)
```

`require_confirm: true` (set on the prod env in `metaphor.deploy.yaml`) means `metaphor deploy push prod` will prompt for `y/N` before doing anything destructive. To bypass in scripted contexts, pass `--yes`.

### What `push` actually does

`metaphor deploy push prod` runs an 8-step sequence end-to-end. The full breakdown is in [DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md). Summary:

1. Resolve the tag (default: short git SHA)
2. Confirm (interactive y/N) if `require_confirm: true`
3. `docker buildx build --platform linux/amd64 --push -t ghcr.io/faridlab/<image>:<tag> …` for each image
4. Update `*_TAG=<sha>` lines in `deployment/.env.prod` locally
5. `scp` the env file to `<user>@<host>:/srv/__project__/.env.prod`
6. `ssh` to host: `docker compose pull`
7. `ssh` to host: `docker compose up -d`
8. Run migrations via `docker compose run --rm migrations …`

### Safety gates

- **`require_confirm`** — prompts before each push. The flag lives in [`metaphor.deploy.yaml`](../metaphor.deploy.yaml).
- **`--dry-run`** — prints every command (build, scp, ssh) without running any of them. Use this on your first deploy.
- **`--skip-build`** — uses already-built images from the registry. Only useful for **promotion** (e.g. uat→prod with the same tag) — see [UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md).
- **`--skip-migrate`** — useful when the change is image-only and you've already migrated, or you want to migrate manually first.

## First-deploy sequence

### Step 1 — Sanity-check the build locally

```bash
metaphor docker up --env dev --build
curl http://localhost:3000/health
metaphor docker down
```

If this fails, fix it before involving the VPS.

### Step 2 — Dry run to verify command shapes

```bash
metaphor deploy push prod --dry-run
```

Read the output carefully. You should see:

- `docker buildx build … --push -t ghcr.io/faridlab/__project__-service:<sha> …` (and the same for webapp + admin)
- `rsync -avz deployment/.env.prod deploy@__project__.com:/srv/__project__/deployment/.env.prod` (or `scp` equivalent depending on metaphor CLI version)
- `ssh deploy@__project__.com 'cd /srv/__project__ && docker compose -f compose.yaml --env-file .env.prod pull'`
- Same for `up -d` and the migrations container

If a command targets the wrong host, wrong directory, or the wrong env file, fix [`metaphor.deploy.yaml`](../metaphor.deploy.yaml) before continuing.

### Step 3 — Bootstrap the VPS deploy directory

The `metaphor deploy push` command transports the **env file** automatically, but the **compose file + supporting directories** are a one-time setup:

```bash
ssh deploy@__project__.com 'sudo mkdir -p /srv/__project__ && sudo chown deploy:deploy /srv/__project__'

# rsync — only changed bytes, supports --dry-run for preview, --delete for cleanup
rsync -avz --delete \
  --exclude='.env.prod.example' --exclude='.gitignore' \
  deployment/ \
  deploy@__project__.com:/srv/__project__/deployment/
```

(After this, only `compose.yaml` updates need re-uploading on schema-style changes; the runtime env file is handled by `deploy push`.)

### Step 4 — The actual deploy

```bash
metaphor deploy push prod
```

You'll see the confirmation prompt (because `require_confirm: true`). Type `y`, hit Enter. The command will:

1. Build and push three images to GHCR (~2-5 min on first run, faster after)
2. Update tags in `.env.prod` and transfer it up (scp/rsync depending on metaphor CLI version)
3. Pull images on the VPS, `up -d`, run migrations

### Step 5 — Verify

See the next section.

## Verification checklist

```bash
# 1. Compose health
metaphor deploy status prod
```

All services should show `running (healthy)`. If any are `unhealthy` or `restarting`, jump to logs:

```bash
metaphor deploy logs prod --service __project__-service --tail 200
```

```bash
# 2. Backend health
curl https://api.__project__.com/health
# expect HTTP 200 with a JSON body
```

```bash
# 3. Frontends serve
curl -I https://app.__project__.com/        # customer
curl -I https://provider.__project__.com/   # provider
curl -I https://admin.__project__.com/      # admin
curl -I https://download.__project__.com/   # provider mobile-app download
# expect HTTP 200 with content-type: text/html
```

```bash
# 4. Cert is real (not Let's Encrypt staging)
echo | openssl s_client -servername api.__project__.com -connect api.__project__.com:443 2>/dev/null \
  | openssl x509 -noout -issuer
# Issuer should mention "Let's Encrypt"; "STAGING" means Caddy is in staging mode
```

```bash
# 5. Observability is reachable
curl -I https://grafana.__project__.com/
# Then log in (user: admin, password from GRAFANA_ADMIN_PASSWORD)
# and confirm the provisioned dashboards under "Dashboards" > "Browse"
```

For the complete first-deploy checklist (file-serving modes A/B/C, monitoring alerts, backup verification), see [deployment/README.md](../deployment/README.md).

## What to do if it fails

### Build/push fails

The command stops before touching the VPS. Re-run `metaphor deploy push prod --dry-run` to see what it was trying to do, fix the cause (network, GHCR auth, Dockerfile error), and re-run.

### scp/ssh fails

```bash
ssh deploy@__project__.com 'echo ok'    # test SSH directly
```

If this hangs or fails, check firewall, SSH keys, and that the deploy user exists.

### `docker compose pull` fails on the VPS

Most likely the VPS isn't logged into GHCR for private images:

```bash
ssh deploy@__project__.com 'echo $GHCR_PAT | docker login ghcr.io -u <user> --password-stdin'
```

### `docker compose up -d` brings up containers but they crash-loop

```bash
metaphor deploy logs prod --service <service> --tail 500
```

Common causes:

- Bad env values (typo in `.env.prod`, e.g. an unescaped `#` in `JWT_HS256_SECRET`)
- DB password mismatch (the service's value vs. what postgres was initialised with)
- DNS not yet propagated → Caddy can't issue certs → service waits

### Recovery for a botched first deploy

For the very first deploy (no users, no data), the realistic recovery is **tear down and retry**:

```bash
ssh deploy@__project__.com 'cd /srv/__project__ && docker compose down -v'
# Fix root cause locally
metaphor deploy push prod
```

After the first successful deploy, **never** use `down -v` (that wipes Postgres data). For ongoing rollbacks see [UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md#rollback).

## See also

- [DEPLOYMENT-PLAN.md](DEPLOYMENT-PLAN.md) — architecture and rationale (subdomain map, file serving modes, observability stack)
- [DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md) — full `metaphor deploy` flag reference
- [deployment/README.md](../deployment/README.md) — VPS-side procedures (backups, monitoring, troubleshooting, restore drill)
- [UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md) — what to do on subsequent deploys
- [metaphor.deploy.yaml](../metaphor.deploy.yaml) — env definitions (`prod` section is what `push prod` reads)
