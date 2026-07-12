# VPS Setup & First Deployment (Hostinger)

> **Goal:** take a freshly purchased Hostinger KVM4 from "no OS yet" to "__PROJECT__ stack running with TLS, monitoring, and backups."
>
> **Time:** ~3–4 hours straight through, or split over a few days. Phases 1 (hardening) and 3 (DNS) benefit from being done early — DNS propagation runs in the background.
>
> **Audience:** the operator deploying __PROJECT__. Not a Docker tutorial — assumes you're comfortable with SSH, can read shell scripts, and know what `dig` does.

## What this doc covers

| Phase | What | Time | Can defer? |
|---|---|---|---|
| 0 | Hostinger panel setup | 5 min | No |
| 1 | Server hardening (SSH, firewall, fail2ban) | 30 min | No |
| 2 | Docker install | 10 min | No |
| 3 | DNS records (10 subdomains) | 5 min config + propagation | No — must be done before Caddy first boots |
| 4 | Build & push images to GHCR | 30–60 min | No |
| 5 | Prepare env files locally | 15 min | No |
| 6 | First deploy — rsync + `docker compose up` | 20 min | No |
| 7 | Smoke test (every subdomain + TLS) | 10 min | No |
| 8 | Backups (B2 + restic + restore drill) | 30 min | Yes, but **before any real users** |

## Prerequisites — have these before starting

- [ ] Hostinger KVM4 purchased (or any Linux VPS with SSH access)
- [ ] SSH key pair on your laptop (`~/.ssh/id_ed25519` — generate with `ssh-keygen -t ed25519` if missing)
- [ ] Domain name registered with DNS access (e.g. `__project__.com`)
- [ ] GitHub PAT with `read:packages` scope for pulling images from GHCR ([create here](https://github.com/settings/tokens))
- [ ] Backblaze B2 account for off-site backups (free tier is enough — defer to Phase 8 if needed)
- [ ] This workspace cloned and ready on your laptop, with all the work in this branch committed

---

## Phase 0 — Hostinger control panel (5 min)

In the Hostinger VPS panel:

- [ ] **OS:** select **Ubuntu 24.04 LTS** (clean, well-supported, what `cargo-chef` and Docker assume)
- [ ] **Datacenter:** **Singapore** (lowest latency to Indonesian users; ~30–50 ms vs 250+ ms from EU/US)
- [ ] **Hostname:** something like `__project__-prod`
- [ ] **SSH key:** paste the contents of `~/.ssh/id_ed25519.pub` BEFORE first boot. If you can't, you'll get a temporary root password emailed and have to add the key manually first thing.
- [ ] **Note the IPv4 address** Hostinger assigns — you need it for SSH and DNS

⚠️ Hostinger sometimes ignores the SSH key on first provision. If `ssh root@<vps-ip>` asks for a password, use the temp password from the email, then `ssh-copy-id root@<vps-ip>` from your laptop to install the key properly before doing anything else.

---

## Phase 1 — Server hardening (30 min)

SSH in as `root` initially. Everything in this phase is one-time.

```bash
ssh root@<vps-ip>
```

### 1a — Create the `deploy` user

`metaphor.deploy.yaml` expects `ssh_user: deploy`, so the user must be named exactly that.

```bash
adduser --disabled-password --gecos "" deploy
usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh
cp ~/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# Allow deploy to use sudo without re-typing password (optional but convenient)
echo 'deploy ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/deploy
```

### 1b — Lock down SSH

```bash
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# On Ubuntu/Debian the service is `ssh`. (On RHEL/CentOS/Fedora it's `sshd`.)
sshd -t && systemctl restart ssh        # `sshd -t` validates the config first
```

⚠️ **Verify from a NEW terminal BEFORE closing this one** (so you don't lock yourself out if something's broken):

```bash
# In a new terminal:
ssh deploy@<vps-ip>     # should work
ssh root@<vps-ip>       # should fail with "Permission denied (publickey)"
```

### 1c — Firewall (UFW)

Allow only what Caddy needs:

```bash
apt update
apt install -y ufw fail2ban unattended-upgrades

ufw allow 22/tcp        # SSH
ufw allow 80/tcp        # HTTP (Let's Encrypt ACME challenge + redirect to HTTPS)
ufw allow 443/tcp       # HTTPS
ufw allow 443/udp       # HTTP/3 (QUIC)
ufw --force enable
ufw status              # confirm
```

### 1d — Auto security updates

```bash
dpkg-reconfigure -plow unattended-upgrades   # answer "yes"
```

### 1e — fail2ban (auto-ban brute-force SSH attempts)

The default config bans IPs after 5 failed attempts for 10 minutes. Good enough for now:

```bash
systemctl enable --now fail2ban
fail2ban-client status sshd      # should show "Active"
```

### 1f — Timezone & hostname

```bash
timedatectl set-timezone Asia/Jakarta
hostnamectl set-hostname __project__-prod
```

### 1g — Apply pending updates + reboot

```bash
apt full-upgrade -y
reboot
```

---

## Phase 2 — Docker install (10 min)

After reboot, SSH back in as **`deploy`**:

```bash
ssh deploy@<vps-ip>
```

### 2a — Install Docker from the official repo

The Ubuntu apt version is too old. Use Docker's official repo:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list

sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

### 2b — Let `deploy` use Docker without sudo

```bash
sudo usermod -aG docker deploy
exit                  # log out — group change takes effect on next login
```

```bash
# Verify
ssh deploy@<vps-ip>
docker run --rm hello-world         # prints the welcome message
docker compose version              # prints v2.x
docker buildx version               # prints buildx info
```

---

## Phase 3 — DNS setup (5 min config + propagation)

⚠️ **This MUST happen before you start Caddy.** Caddy issues TLS certs via Let's Encrypt's ACME HTTP-01 challenge — it needs each subdomain's DNS to already point at the VPS, otherwise issuance fails. Let's Encrypt has a **rate limit of 50 failures per hour per domain**; if you trip it, you wait.

### Records to create

In your DNS host's panel (Hostinger if that's where the domain lives, or wherever you registered), create **10 A records**, all pointing to your VPS IPv4:

| Subdomain | Type | TTL | Points to |
|---|---|---|---|
| `api.__project__.com` | A | 300 | `<vps-ip>` |
| `grpc.__project__.com` | A | 300 | `<vps-ip>` |
| `app.__project__.com` | A | 300 | `<vps-ip>` |
| `provider.__project__.com` | A | 300 | `<vps-ip>` |
| `admin.__project__.com` | A | 300 | `<vps-ip>` |
| `download.__project__.com` | A | 300 | `<vps-ip>` |
| `bucket.__project__.com` | A | 300 | `<vps-ip>` |
| `s3.__project__.com` | A | 300 | `<vps-ip>` |
| `invoice.__project__.com` | A | 300 | `<vps-ip>` |
| `grafana.__project__.com` | A | 300 | `<vps-ip>` |
| `status.__project__.com` | A | 300 | `<vps-ip>` |

> The apex `__project__.com` itself isn't routed by Caddy yet — it would 404. Decide what (if anything) should live there before public launch (marketing landing page, redirect to `app.`, etc.).

### Verify propagation

Wait 5–30 min, then from your laptop:

```bash
for sub in api grpc app provider admin download bucket s3 invoice grafana status; do
  printf '%-10s → %s\n' "$sub" "$(dig +short $sub.__project__.com)"
done
# Every line should show your VPS IP.
```

If any return blank or an old IP, wait another 10 min and re-check. Don't proceed to Phase 6 (deploy) until all 11 resolve correctly.

---

## Phase 4 — Build & push images to GHCR (30–60 min)

You have CI workflows committed for `__project__-service` and `__project__-mobile-provider`. The 4 webapps don't have CI yet. For the first deploy, two paths — pick one:

### Path A — Build everything locally (fastest first deploy, recommended)

Uses `metaphor deploy push` to build all 5 images at once and push to GHCR. Good for the first deploy because nothing needs to exist in GHCR yet.

```bash
cd path/to/__project__-metaphor

# Login to GHCR (one-time per machine)
echo $GHCR_PAT | docker login ghcr.io -u faridlab --password-stdin
# PAT scope needed: write:packages (for pushing)

# Dry run first to see what would happen
metaphor deploy push prod --dry-run

# Then for real (uses git short SHA as the tag for all 5 images)
metaphor deploy push prod
```

This builds + pushes:
- `ghcr.io/faridlab/__project__-service:<sha>`
- `ghcr.io/faridlab/__project__-webapp-customer:<sha>`
- `ghcr.io/faridlab/__project__-webapp-provider:<sha>`
- `ghcr.io/faridlab/__project__-webapp-admin:<sha>`
- `ghcr.io/faridlab/__project__-webapp-download:<sha>`

### Path B — CI builds the service, you build webapps locally (cleaner for ongoing releases)

```bash
# Push the __project__-service repo so CI can run
cd apps/__project__-service
git push                          # pushes the unpushed commits

# Tag a release — CI builds + publishes ghcr.io/.../__project__-service:v0.1.0
git tag v0.1.0
git push --tags
# Watch: https://github.com/faridlab/__project__-service/actions

# Wait for CI to finish (~5–8 min). Verify the image landed:
# https://github.com/faridlab/__project__-service/pkgs/container/__project__-service

# For webapps: build locally for now (CI for them is a future task)
cd ../..
metaphor deploy push prod         # ⚠️ this will ALSO rebuild __project__-service locally,
                                  #    overwriting the CI image. To avoid:
# metaphor deploy push prod --skip-build   # skip-build is global, all-or-nothing
                                  #    so for path B you essentially need to
                                  #    edit .env.prod by hand and skip
                                  #    metaphor deploy push for service.
```

**For your first deploy, Path A is simpler.** Switch to Path B once CI is set up for the webapps too.

---

## Phase 5 — Prepare env files locally (15 min)

The __PROJECT__ env model has **two files** per environment:
- `deployment/.env.prod` — orchestration (image tags, infra creds, edge config)
- `apps/__project__-service/.env.prod` — service runtime config (JWT, MinIO access, log level, etc.)

Both are gitignored. The contracts (`.env.prod.example`) are committed.

### 5a — Service runtime config

```bash
cd path/to/__project__-metaphor

cp apps/__project__-service/.env.prod.example apps/__project__-service/.env.prod
chmod 600 apps/__project__-service/.env.prod
$EDITOR apps/__project__-service/.env.prod
```

Fill in every `CHANGE_ME_*` value. Generators:

```bash
# Strong random secrets (paste into JWT_SECRET, CSRF_SECRET, SESSION_SECRET, BUCKET_LOCAL_SIGNING_SECRET)
openssl rand -base64 64 | tr -d '\n'

# Encryption key (ENCRYPTION_KEY — 32 bytes base64)
openssl rand -base64 32

# Encryption IV (ENCRYPTION_IV — 16 bytes base64)
openssl rand -base64 16
```

⚠️ Once `ENCRYPTION_KEY` and `ENCRYPTION_IV` are set, **do not change them** without a re-encryption migration — encrypted columns become unreadable. Back them up to your password manager alongside the keystore.

### 5b — Orchestration config

```bash
cp deployment/.env.prod.example deployment/.env.prod
chmod 600 deployment/.env.prod
$EDITOR deployment/.env.prod
```

Fill in:
- `DOMAIN`, `ACME_EMAIL`
- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` (use a strong random password)
- `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` (admin creds for the MinIO container)
- `MINIO_PRIVATE_BUCKET`, `MINIO_PUBLIC_BUCKET`
- `GRAFANA_ADMIN_PASSWORD`
- `SMTP_*` (your email provider's creds)
- `EMAIL_FROM`, `EMAIL_FROM_NAME`

Then pin the image tags you just pushed in Phase 4:

```bash
SHA=$(git rev-parse --short HEAD)        # or v0.1.0 if you used Path B
sed -i "s/^SERVICE_TAG=.*/SERVICE_TAG=$SHA/"                 deployment/.env.prod
sed -i "s/^WEBAPP_CUSTOMER_TAG=.*/WEBAPP_CUSTOMER_TAG=$SHA/" deployment/.env.prod
sed -i "s/^WEBAPP_PROVIDER_TAG=.*/WEBAPP_PROVIDER_TAG=$SHA/" deployment/.env.prod
sed -i "s/^WEBAPP_ADMIN_TAG=.*/WEBAPP_ADMIN_TAG=$SHA/"       deployment/.env.prod
sed -i "s/^WEBAPP_DOWNLOAD_TAG=.*/WEBAPP_DOWNLOAD_TAG=$SHA/" deployment/.env.prod
```

### 5c — Validate everything

```bash
metaphor deploy preflight prod
# Expect green checks:
#   ✓ <service>: all N contract vars present   (one line per service with a .env.prod.example)
#   ✓ all compose-interpolated vars resolve     (every ${VAR:?...} in compose.yaml resolves)
# → "✓ preflight passed"
```

If preflight is red, fix locally before continuing — DO NOT push a broken env file.

---

## Phase 6 — First deploy (20 min)

### 6a — Create the directory structure on the VPS

The VPS layout mirrors the workspace (so compose's `env_file:` paths resolve identically in both contexts):

```bash
ssh deploy@<vps-ip> "mkdir -p /srv/__project__/deployment /srv/__project__/apps/__project__-service"
```

### 6b — Sync files from your laptop

We use `rsync` instead of `scp` — only changed bytes get transferred (massive
win on repeat deploys), `--delete` cleans up files removed locally, and
`--dry-run` lets you preview before pushing.

```bash
# Preview what would change first (always do this — catches mistakes)
rsync -avz --delete --dry-run \
  --exclude='.env.prod.example' \
  --exclude='.gitignore' \
  deployment/ \
  deploy@<vps-ip>:/srv/__project__/deployment/

# Looks right? Drop --dry-run to actually sync
rsync -avz --delete \
  --exclude='.env.prod.example' \
  --exclude='.gitignore' \
  deployment/ \
  deploy@<vps-ip>:/srv/__project__/deployment/

# Service runtime env (lives WITH the service, not under deployment/)
rsync -avz \
  apps/__project__-service/.env.prod \
  deploy@<vps-ip>:/srv/__project__/apps/__project__-service/.env.prod
```

> ⚠️ Trailing slashes matter for rsync. `deployment/` (with slash) means
> "contents of deployment". Without the slash, you'd get
> `/srv/__project__/deployment/deployment/` — wrong layout.

### 6c — Bring the stack up

```bash
ssh deploy@<vps-ip>
cd /srv/__project__/deployment

# GHCR login (one-time per VPS)
echo $GHCR_PAT_READONLY | docker login ghcr.io -u faridlab --password-stdin
# This PAT only needs `read:packages` scope (not write — VPS doesn't push)

# Pull all images
docker compose --env-file .env.prod pull

# Start the whole stack
docker compose --env-file .env.prod up -d

# Watch service logs as it boots
docker compose --env-file .env.prod logs -f __project__-service
# Ctrl-C to detach (doesn't stop the container)

# Verify all containers healthy
docker compose --env-file .env.prod ps
```

If any container is `Restarting` or `Exited`, see [Troubleshooting](#troubleshooting) below.

### 6d — Apply database migrations

The `__project__-service migrate` subcommand is currently a placeholder (logs a warning, exits 0). Until it's wired up, run migrations from your laptop via an SSH tunnel:

```bash
# On your laptop — open a tunnel to the VPS Postgres
ssh -N -L 5433:postgres:5432 deploy@<vps-ip> &

# Read DB creds from your local deployment/.env.prod
source deployment/.env.prod

# Apply migrations (uses metaphor CLI from the workspace)
DATABASE_URL=postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@127.0.0.1:5433/$POSTGRES_DB \
  metaphor migration run-all

# Tear down the tunnel when done
kill %1
```

---

## Phase 7 — Smoke test (10 min)

From your laptop, hit every endpoint:

### 7a — Backend health

```bash
curl https://api.__project__.com/health | jq
# Expect: { status: "healthy", service: "__project__-service",
#          version: "<your tag>", commit: "<sha>", built_at: "...",
#          components: { ... } }
```

### 7b — Frontends serve

```bash
curl -I https://app.__project__.com/        # customer  → 200, content-type: text/html
curl -I https://provider.__project__.com/   # provider  → 200
curl -I https://admin.__project__.com/      # admin     → 200
curl -I https://download.__project__.com/   # download  → 200
```

### 7c — TLS is real (not Let's Encrypt staging)

```bash
echo | openssl s_client -servername api.__project__.com -connect api.__project__.com:443 2>/dev/null \
  | openssl x509 -noout -issuer
# Expect: issuer mentions "Let's Encrypt"
# If it says "STAGING" or "Pebble", Caddy is in test mode — see troubleshooting
```

### 7d — File serving (MinIO modes)

```bash
# Mode A — public bucket, direct from MinIO (after you've uploaded a test asset)
curl -I https://bucket.__project__.com/public/<some-key>

# Mode C — raw MinIO presigned URL endpoint (sanity check it's reachable)
curl -I https://s3.__project__.com/                # 403 from MinIO is expected (no auth)
```

### 7e — Grafana

```bash
curl -I https://grafana.__project__.com/   # 302 → /login
```

Then in a browser, log in with `admin` / your `GRAFANA_ADMIN_PASSWORD`. Verify the three __PROJECT__ dashboards loaded (Golden Signals, Postgres Health, Host & Container Resources).

### 7f — Status page

```bash
curl -I https://status.__project__.com/    # 200, uptime-kuma UI
```

In a browser, set up monitors for each subdomain.

---

## Phase 8 — Backups (30 min — do BEFORE real users hit the system)

Detailed instructions are in [`deployment/README.md`](../deployment/README.md) "Backups" section. Summary:

1. Create a Backblaze B2 account + bucket (`__project__-backups` or similar). Free tier is 10 GB — enough for months of pg dumps.
2. Generate a B2 application key with read/write access to that bucket.
3. SSH to the VPS and create `/etc/default/restic` (chmod 600) with:
   ```
   RESTIC_REPOSITORY=b2:__project__-backups:/prod
   RESTIC_PASSWORD=<long-random-string>     # repo encryption key — back this up!
   B2_ACCOUNT_ID=<keyID>
   B2_ACCOUNT_KEY=<applicationKey>
   ```
4. Initialize the restic repo: `sudo restic -r "$RESTIC_REPOSITORY" init`
5. Install the cron jobs (nightly pg-backup.sh, weekly restic-push.sh, monthly restic-check.sh) — exact commands in `deployment/README.md`.
6. **Run the restore drill** (also in `deployment/README.md`) — this is the single most important pre-launch step. A backup you've never restored is not a backup.

---

## Troubleshooting

### `permission denied (publickey)` on first SSH

Your key wasn't installed before first boot. Use the Hostinger panel's VNC console to log in with the temp password, then `ssh-copy-id` from your laptop.

### TLS cert issuance fails / "could not solve challenge"

DNS hasn't propagated yet. Verify with `dig +short api.__project__.com` — should return your VPS IP. Wait 10–15 min and `docker compose restart caddy`. Don't restart Caddy more than ~10 times in an hour or you'll trip Let's Encrypt's rate limit (50 failures/hour/domain).

### `denied: requested resource not allowed` on `docker pull`

Your GHCR PAT lacks the `read:packages` scope, OR your image is private and the PAT user doesn't have access. Recreate the PAT with the right scope and re-`docker login`.

### `__project__-service` in restart loop

```bash
docker compose --env-file .env.prod logs __project__-service | tail -50
```

Common causes:
- `DATABASE_URL` wrong (postgres not reachable, wrong creds)
- Required env var missing (preflight should have caught this)
- Migrations not applied → service panics on schema mismatch (run Phase 6d)

### `migrations` container fails / exits non-zero

The `migrate` subcommand is a placeholder right now. Run migrations manually via the SSH-tunnel pattern in Phase 6d. The migrations container will retry on every `up -d` and keep failing until the binary's `migrate` is wired to the real `MigrationManager` — track this as an upgrade.

### Compose says "required variable X is missing a value"

Your `.env.prod` is missing a required var. The strict syntax is doing its job — fix the missing var, re-scp, retry. Use `metaphor deploy preflight prod` locally first to catch this before scp.

### Service `/health` shows `version: "unknown"`

Build environment didn't have `git` available during `cargo build`, AND `APP_VERSION` env var wasn't set. Rebuild with proper build args (see `apps/__project__-service/docs/RELEASING.md`). For local builds, just ensure you're inside a git checkout.

### `bucket.__project__.com/<key>` returns 302 to `127.0.0.1` or `minio:9000`

`MINIO_PUBLIC_ENDPOINT` in `deployment/.env.prod` is wrong. Should be `https://s3.${DOMAIN}` (compose constructs this — make sure `DOMAIN` is set).

---

## Things to do AFTER the first deploy is green

In rough priority order:

1. **Push remaining commits** — the metaphor workspace, `__project__-service`, and `__project__-mobile-provider` repos all have unpushed work. Push them so the work isn't laptop-only.

2. **Set up Grafana alerts properly** — the workspace ships 5 alert rules (5xx rate, p95 latency, postgres connections, host disk > 80%, container restart loop). Verify they fire by triggering a synthetic 500. Configure recipient email under `grafana/provisioning/alerting/contact-points.yml`.

3. **uptime-kuma monitors** — log into `https://status.__project__.com`, add HTTP monitors for `api.__project__.com/health` (1-min interval), each frontend, and the bucket endpoint. Set up email/Telegram notification.

4. **First mobile release** — `cd apps/__project__-mobile-provider && git tag v0.1.0 && git push --tags`. CI builds the signed APK and attaches to a GitHub Release. The `download.__project__.com` page already links to `releases/latest/download/__project__-provider.apk`.

5. **Set up CI for the 4 webapps** (mirror the __project__-service workflow pattern). Until then, every webapp release is `metaphor deploy push prod` from your laptop.

6. **Rotate any secrets that appeared in chat history** during this conversation (especially `JWT_SECRET` if you used the value from your dev `.env`).

7. **File a metaphor CLI feature request** for "preserve `deployment/` subdir on transfer" so `metaphor deploy push` works seamlessly with the new VPS layout. Workaround until then: manual `rsync` for full deploys, surgical `metaphor deploy service <env> <svc> <tag>` for image-tag bumps.

---

## Where to go from here

| For… | Read |
|---|---|
| Day-to-day deploys (image tag bumps, rollbacks, release loop) | [docs/UPDATING-DEPLOYMENTS.md](UPDATING-DEPLOYMENTS.md) |
| Architecture deep dive (subdomain map, file-serving modes, observability) | [docs/DEPLOYMENT-PLAN.md](DEPLOYMENT-PLAN.md) |
| `metaphor docker` / `metaphor deploy` CLI reference | [docs/DEPLOY-COMMANDS.md](DEPLOY-COMMANDS.md) |
| Operator runbook (backups, restore, common tasks on the VPS) | [deployment/README.md](../deployment/README.md) |
| Releasing __project__-service via CI | [apps/__project__-service/docs/RELEASING.md](../apps/__project__-service/docs/RELEASING.md) |
| Releasing the provider mobile app | [apps/__project__-mobile-provider/docs/RELEASING.md](../apps/__project__-mobile-provider/docs/RELEASING.md) |
