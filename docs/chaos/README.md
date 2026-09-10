# Chaos engineering — the post-change resilience gate

> This workspace treats chaos engineering as a **quality gate that runs after
> business-flow-level changes**, the same way tests and review do. This doc is
> the practice definition. Adapt it to this product's real dependencies —
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

## 5. Experiment catalog (starting set)

One fault per experiment; each names fault, hypothesis, blast radius,
injection, restore. A parameterized driver (`deployment/chaos/run.sh` +
per-experiment scripts) ships in a later framework train — until then, run
these as documented manual procedures or port the kit from the reference
implementation (the serpa workspace pilot).

| # | Experiment | Injection (dev compose) | Steady-state expectation |
|---|---|---|---|
| 1 | database-loss | `docker compose stop postgres` | typed 5xx/refusals, no hangs; pool reconnects and all probes green after start |
| 2 | database-restart-midwrite | restart postgres while the canary flow writes | no lost/duplicated writes; consistent state after recovery |
| 3 | object-storage-loss | `docker compose stop <storage>` | storage-dependent flows fail closed; others healthy; clean recovery |
| 4 | dependency-service-loss | stop a composed supporting service | remaining flows keep serving; fences do NOT fail open |
| 5 | service-kill-midflow | kill the app container mid canary flow | state consistent after restart; flow completes or fails cleanly |
| 6 | pool-exhaustion | hold DB connections to `max_connections` | controlled errors, no pool leak; recovery after release |
| 7 | secret-fail-closed | recreate a service with one required secret empty | boot fails loudly OR that surface refuses typed; never silent misbehavior |
| 8 | maintenance-mode | enable the maintenance gate | clean refusal for traffic, truthful status, allow-listed paths stay up, clean clear |
| 9 | tenancy-fence-under-fault (if multi-tenant) | pair #1/#4 with tenancy probes running | the fence is still enforced while a dependency is degraded |

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

1. **Manual/procedural** (this doc) — experiments run as documented steps.
2. **Parameterized kit** — `deployment/chaos/` driver + experiment scripts
   generated per workspace (ships in a framework train once the serpa pilot
   validates the catalog).
3. **Skill pack** — a `chaos-engineering` skill in the metaphor-agent pack;
   `metaphor chaos` CLI once the catalog is stable.
4. **uat/prod game days** — only after observability and abort-safety are
   proven, with explicit owner approval.
