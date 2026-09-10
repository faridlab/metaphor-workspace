# Chaos engineering — the post-change resilience gate

> This workspace treats chaos engineering as a **quality gate that runs after
> business-flow-level changes**, the same way tests and review do. This doc is
> the practice definition. The kit under `deployment/chaos/` is
> parameterized; adapt the practice to this product's real dependencies —
> delete what does not apply, add what exists here.

## 1. What this is (and is not)

- **Is**: automated, repeatable fault experiments against the dev stack that
  prove the steady state holds while a dependency fails — and that the stack
  recovers cleanly once the fault is withdrawn.
- **Is not**: ad-hoc breakage, a load test, or a substitute for tests/review.
  Chaos complements the existing gates; it never replaces them.

Core principles:

1. **Steady state before chaos** — define measurable normal behavior before
   injecting anything. Without a steady state, chaos is just breaking things.
2. **Explicit hypothesis** — write "steady state holds under fault X" first;
   judge against the hypothesis, not vibes.
3. **Vary real-world events** — inject failures that actually happen in
   production: database loss, object-storage loss, crashes, exhausted pools,
   missing secrets.
4. **Smallest blast radius that still teaches** — one dependency at a time,
   dev stack first.
5. **Automatic abort + rollback** — every experiment has a one-command
   restore and a trap that fires it on exit, even on error.
6. **Automate and repeat** — experiments are deterministic scripts; a run
   that cannot be re-run is not evidence.
7. **Findings ledger** — pass = resilience assumption proven (recorded);
   fail = defect (file an issue in the tracker). Commit run logs as evidence.

## 2. The gate — when a chaos run is mandatory

Run the gate when a change does ANY of:

- adds/changes a **business flow** (route + service + entity forming an
  end-user flow),
- adds/changes a **cross-module seam** (module A now calls/expects module B),
- adds a **new external dependency** (queue, cache, storage, provider),
- touches **tenancy / RLS / auth / fences**,
- touches **runtime infrastructure** (pools, workers, deploy stack, proxy,
  migration runner).

**Exempt**: typos, copy, formatting, comments, docs-only, tests-only,
behavior-identical refactors. Running chaos on those wastes the stack.

## 3. The cycle (every experiment, every time)

1. **Baseline** — steady-state probes on the healthy stack; must be green
   before anything is injected. Red baseline = abort, fix the stack first.
2. **Hypothesis** — one sentence: what must hold under the fault.
3. **Scope** — one fault, minimal blast radius, dev environment only.
4. **Inject** — run the fault while probes observe.
5. **Observe & compare** — steady state held? Failures are *controlled*
   (typed errors/refusals, no hangs, no panics, no corruption)? Recovery is
   clean after the fault is withdrawn?
6. **Restore & record** — rollback, verdict (pass/fail), run log committed;
   on fail → issue in the tracker.

## 4. Define this workspace's steady state

Fill these in for THIS product and keep them green before any experiment:

| Probe | What | Where |
|---|---|---|
| Liveness | `GET /livez` answers 200 while running | `__project__-service` |
| Readiness | `GET /readyz` answers 200 only when dependencies actually serve | `__project__-service` |
| Canary flow | one real end-user journey (guest → outcome) executed end-to-end | `__project__-service` |
| Tenancy fence (if multi-tenant) | requests without a valid tenant resolve fail closed (404/401), never 5xx | `__project__-service` |

Probing rules: target the stack by explicit `127.0.0.1` (never `localhost`,
which may resolve to `::1` while the stack binds IPv4 only); treat a probe
that *skips* as a failure, not a pass.

**How the kit encodes this table:** liveness + readiness are the health-only
steady state (always on). The canary-flow and tenancy rows come from the
**product hook**: copy `deployment/chaos/lib/steady-state.sh.example` to
`deployment/chaos/lib/steady-state.sh` and implement `flow_canary LABEL`
(and `tenancy_sweep` if multi-tenant) as thin wrappers over this product's
own committed probe scripts — the kit picks the hook up on the next run and
adds those legs to baseline/recovery (`--full`). Until the hook is installed
those legs record as **SKIP**: the gate still runs, just shallower. Keep
probe logic in the app repo, not in the kit.

## 5. The kit — `deployment/chaos/`

The parameterized kit ships with this template (`metaphor init` stamps
`__project__` into it like everywhere else). Bash + docker compose only,
serial, safe to re-run.

```bash
deployment/chaos/run.sh list              # catalog, one per line
deployment/chaos/run.sh --dry-run all     # print every action + check, touch nothing
deployment/chaos/run.sh postgres-loss     # one experiment, live
deployment/chaos/run.sh --full all        # + canary/tenancy legs (needs the hook; slow)
```

Layout:

- `run.sh` — serial driver. Each experiment runs in its own subshell with an
  abort trap that restores the stack on ANY exit; baseline must be green
  before anything is injected; verdict + `chaos_exit=` line at the end.
- `lib/common.sh` — compose wrappers (`deployment/.env.dev` optional), HTTP
  and postgres probes, the check ledger, and the **stack wiring**
  (`SERVICE_NAME`, `CONTROL_PLANE_SERVICE`, base URLs) — the single place to
  rebind names if this workspace's compose differs.
- `lib/steady-state.sh.example` — the product hook template (§4).
- `experiments/<name>.sh` — one fault per file, each documenting fault,
  hypothesis, blast radius, and restore.
- `runlogs/` — committed evidence, one log per experiment per day.

Catalog (run serially, in this order):

| # | Experiment | Injection (dev compose) | Steady-state expectation |
|---|---|---|---|
| 1 | postgres-loss | `stop postgres` | typed 5xx/refusals, no hangs; pool reconnects and all probes green after start |
| 2 | postgres-restart-midwrite | restart postgres while the canary flow writes (--full) | no lost/duplicated writes; consistent state after recovery |
| 3 | minio-loss | `stop minio` | storage-dependent flows fail closed; others healthy; clean recovery |
| 4 | control-plane-loss | stop the control plane (if the compose runs one) | remaining flows keep serving; fences do NOT fail open |
| 5 | service-kill-midflow | kill the service container mid canary flow (--full) | state consistent after restart; flow completes or fails cleanly |
| 6 | pool-exhaustion | hold DB connections to `max_connections` | controlled errors, no pool leak; recovery after release |
| 7 | secret-fail-closed | recreate the service with one optional secret emptied | boot fails loudly OR that surface refuses typed; never silent misbehavior |
| 8 | maintenance-mode | arm + enable the maintenance gate | clean refusal for traffic, truthful status, allow-listed paths stay up, clean clear |
| 9 | tenancy-fence-under-fault | #4 while the tenant-resolution surface is probed | the fence is still enforced while a dependency is degraded |

Skips are honest, not failures: an experiment whose target service the
compose does not declare (a control plane, by default) **skips**; so does
`secret-fail-closed` until `CHAOS_SECRET_ENV_VAR` names an optional secret,
and the canary/sweep legs until the steady-state hook exists.

Knobs (env or defaults in `lib/common.sh`): `SERVICE_BASE_URL`
(127.0.0.1:3000), `CONTROL_PLANE_BASE_URL` (127.0.0.1:3210),
`CHAOS_SECRET_ENV_VAR`, `CHAOS_GATED_PATH` (default `/api/v1`),
`CHAOS_TENANCY_API_PATH`, `CHAOS_RESIDENT_SLUG` (falls back to
`TENANT_ZERO_SLUG` in `deployment/.env.dev`), `WAIT_HTTP_TIMEOUT` (180),
`WAIT_SLOW_TIMEOUT` (420).

Deferred until uat/prod tooling exists: network latency/partition, disk
pressure, TLS-edge faults.

## 6. Safety rules (non-negotiable)

- Dev environment only. Never the production stack.
- One fault at a time. Never run while someone else is using the stack.
- Experiments may **stop/start/recreate services** — they may NEVER delete
  volumes, never `compose down -v`, never touch build caches.
- Every experiment arms an abort trap that restores the stack on any exit.
- Secrets are read per-variable from the env file; never echoed.

## 7. Findings

- **Pass** → the resilience assumption is proven for this change; record the
  run (date, experiment, verdict) in the committed run log.
- **Fail** → file an issue in this workspace's tracker with the run log
  attached; the finding rides the normal prioritization.

## 8. Roadmap

1. **Parameterized kit** (landed) — the template ships the driver, the
   shared library, and the nine-experiment catalog; workspaces keep the kit
   after `metaphor init` stamps it, and wire their steady state via the
   `lib/steady-state.sh` hook.
2. **Skill pack** — a `chaos-engineering` skill in the metaphor-agent pack;
   `metaphor chaos` CLI once the catalog is stable.
3. **uat/prod game days** — only after observability and abort-safety are
   proven, with explicit owner approval.
