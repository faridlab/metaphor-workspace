#!/usr/bin/env bash
# Shared helpers for the __project__ chaos kit. Sourced by run.sh (which also
# sources each experiment file). See docs/chaos/README.md for the practice.
#
# Compatibility: stock macOS bash 3.2 — no associative arrays, no mapfile,
# no `source <(...)` (which silently delivers nothing on 3.2).
#
# Error posture: this library does NOT `set -e` — chaos scripts must keep
# running past failed curls so the restore path always executes. Every
# failure is recorded explicitly through the check_* helpers instead.

# ─── Locations ────────────────────────────────────────────────────────────
CHAOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAOS_DIR="$(cd "$CHAOS_LIB_DIR/.." && pwd)"
DEPLOYMENT_DIR="$(cd "$CHAOS_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$DEPLOYMENT_DIR/.." && pwd)"

COMPOSE_FILE="$DEPLOYMENT_DIR/compose.dev.yaml"
ENV_FILE="$DEPLOYMENT_DIR/.env.dev"
OVERRIDES_DIR="$CHAOS_DIR/overrides"
RUNLOGS_DIR="$CHAOS_DIR/runlogs"

# ─── Stack wiring (the single place compose names are bound) ──────────────
# `metaphor init` stamps __project__ across the workspace; the names below
# must match deployment/compose.dev.yaml service keys. A workspace whose
# compose lacks CONTROL_PLANE_SERVICE simply skips the control-plane
# experiments (see require_service).
SERVICE_NAME="__project__-service"
CONTROL_PLANE_SERVICE="__project__-control-plane"

# ─── Endpoints ────────────────────────────────────────────────────────────
# ALWAYS 127.0.0.1 — on this host `localhost` resolves to ::1 first while the
# dev stack binds 127.0.0.1 only; probes against `localhost` skip-false-pass.
SERVICE_BASE_URL="${SERVICE_BASE_URL:-http://127.0.0.1:3000}"
CONTROL_PLANE_BASE_URL="${CONTROL_PLANE_BASE_URL:-http://127.0.0.1:3210}"

# ─── Modes / knobs (env-overridable) ──────────────────────────────────────
DRY_RUN="${DRY_RUN:-0}"            # 1 = print every action, touch nothing
CHAOS_FULL="${CHAOS_FULL:-0}"      # 1 = add the business-flow legs (slow)
CHAOS_VERBOSE="${CHAOS_VERBOSE:-0}"
WAIT_HTTP_TIMEOUT="${WAIT_HTTP_TIMEOUT:-180}"   # warm restart window (s)
WAIT_SLOW_TIMEOUT="${WAIT_SLOW_TIMEOUT:-420}"   # container-recreate window (s)

# ─── Result ledger (reset per experiment by the driver) ───────────────────
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
FAILED_DETAILS=""

# ─── Logging ──────────────────────────────────────────────────────────────
log()  { printf '%s\n' "$*"; }
vlog() { [ "$CHAOS_VERBOSE" = "1" ] && printf '  %s\n' "$*" || true; }

note() { printf '    note: %s\n' "$*"; }

# ─── Env-file access (never echo other secrets) ───────────────────────────
# The env file is OPTIONAL: a workspace without deployment/.env.dev falls
# back to compose's own variable resolution, and the postgres helpers read
# their credentials from inside the container instead.
env_value() { # VAR — prints the var's value from deployment/.env.dev
    [ -f "$ENV_FILE" ] || return 0
    awk -F= -v key="$1" '$0 ~ "^"key"=" {sub("^"key"=", ""); print; exit}' "$ENV_FILE"
}

# ─── Compose wrappers ─────────────────────────────────────────────────────
compose_base() { # args… — dev stack with NO override
    if [ -f "$ENV_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
    else
        docker compose -f "$COMPOSE_FILE" "$@"
    fi
}

compose_ov() { # OVERRIDE_FILE args… — dev stack + one chaos override
    local ovf="$1"; shift
    if [ -f "$ENV_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" -f "$ovf" --env-file "$ENV_FILE" "$@"
    else
        docker compose -f "$COMPOSE_FILE" -f "$ovf" "$@"
    fi
}

# ─── Execution (dry-run aware) ────────────────────────────────────────────
_fmt_cmd() { # pretty-print: expand the compose wrapper functions
    case "$1" in
        compose_base) printf 'docker compose [dev] %s' "${*:2}" ;;
        compose_ov)   printf 'docker compose [dev+%s] %s' "$(basename "$2")" "${*:3}" ;;
        *)            printf '%s' "$*" ;;
    esac
}

run() { # cmd args… — mutating or side-effecting command
    if [ "$DRY_RUN" = "1" ]; then
        printf '  [dry-run] %s\n' "$(_fmt_cmd "$@")"
        return 0
    fi
    vlog "run: $(_fmt_cmd "$@")"
    "$@"
}

run_sh() { # 'shell string' — for commands that need shell syntax
    if [ "$DRY_RUN" = "1" ]; then
        printf '  [dry-run] %s\n' "$*"
        return 0
    fi
    vlog "run: $*"
    bash -c "$*"
}

mark_injected() { # arms the abort trap — call the moment the fault is live
    INJECTED=1
    trap on_experiment_exit EXIT
}

# Abort/rollback path. Fired by the EXIT trap whenever an experiment that
# injected a fault ends before its own restore completed. Best-effort: it
# starts every service and re-applies the base compose (which also drops any
# override-recreated env). NEVER deletes volumes — volumes are untouchable.
restore_stack() {
    if [ "$DRY_RUN" = "1" ]; then
        log "  [dry-run] restore: compose start <all> + compose up -d"
        return 0
    fi
    log "  !! restoring dev stack (abort path)"
    compose_base start >/dev/null 2>&1 || true
    compose_base up -d >/dev/null 2>&1 || true
    log "  !! restore issued — verify with: docker compose -f deployment/compose.dev.yaml ps"
}

on_experiment_exit() {
    local rc=$?
    if [ "${INJECTED:-0}" = "1" ] && [ "${RESTORED:-0}" != "1" ]; then
        restore_stack
    fi
    exit "$rc"
}

# ─── Service presence (skip machinery) ────────────────────────────────────
# Experiments target optional services (a control plane, say) call
# require_service at the top of the experiment file; a stack that does not
# run the service skips the experiment instead of failing it.
service_in_compose() { # SERVICE — 0 iff the dev compose declares the service
    compose_base config --services 2>/dev/null | grep -qx "$1"
}

require_service() { # SERVICE REASON — exit 2 (skip) when the service is absent
    if ! service_in_compose "$1"; then
        log "SKIP: ${EXPERIMENT_NAME:-experiment} — service '$1' is not part of this stack ($2)"
        exit 2
    fi
}

# ─── HTTP probes (read-only) ──────────────────────────────────────────────
http_code() { # PATH [timeout_sec] [base_url] — prints the status code
    local path="$1" timeout="${2:-10}" base="${3:-$SERVICE_BASE_URL}"
    curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" "$base$path"
}

http_code_h() { # PATH HEADER VALUE [timeout_sec] — status code with one extra
                # request header. VALUE `__absent__` sends NO header at all
                # (for A/B-ing a header-gated surface with one helper).
    local path="$1" header="$2" value="$3" timeout="${4:-10}"
    if [ "$value" = "__absent__" ]; then
        curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" "$SERVICE_BASE_URL$path"
    else
        curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" \
            -H "$header: $value" "$SERVICE_BASE_URL$path"
    fi
}

http_header() { # PATH HEADER [timeout_sec] — prints the header value (lowercased by curl)
    local path="$1" header="$2" timeout="${3:-10}"
    curl -s -o /dev/null -D - --max-time "$timeout" "$SERVICE_BASE_URL$path" \
        | tr -d '\r' | awk -F': ' -v h="$(printf '%s' "$header" | tr 'A-Z' 'a-z')" \
            'tolower($1)==h {print $2; exit}'
}

# ─── Postgres probes (inside the postgres container — no host psql needed) ─
pg_is_up() {
    [ "$DRY_RUN" = "1" ] && return 0
    # The container knows its own POSTGRES_USER/POSTGRES_DB — no host-side
    # env file required.
    compose_base exec -T postgres \
        sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1
}

# Credentials for the psql CLI: prefer the env file (cached after first
# use); fall back to reading them from inside the container.
PG_USER=""
PG_DB=""
_pg_creds() {
    if [ -z "$PG_USER" ] || [ -z "$PG_DB" ]; then
        if [ -f "$ENV_FILE" ]; then
            PG_USER="$(env_value POSTGRES_USER)"
            PG_DB="$(env_value POSTGRES_DB)"
        fi
    fi
    if [ -z "$PG_USER" ] || [ -z "$PG_DB" ]; then
        PG_USER="$(compose_base exec -T postgres printenv POSTGRES_USER 2>/dev/null)"
        PG_DB="$(compose_base exec -T postgres printenv POSTGRES_DB 2>/dev/null)"
    fi
}

pg_scalar() { # SQL — prints one value
    _pg_creds
    compose_base exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

# ─── Wait helpers (live mode only; dry-run callers skip these) ────────────
wait_readyz() { # TIMEOUT — poll /readyz until 200
    local deadline=$(( $(date +%s) + $1 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(http_code /readyz 5)" = "200" ] && return 0
        sleep 2
    done
    return 1
}

wait_service_running() { # SERVICE TIMEOUT
    local svc="$1" deadline=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        compose_base ps --status running --services 2>/dev/null | grep -qx "$svc" && return 0
        sleep 2
    done
    return 1
}

wait_pg_up() { # TIMEOUT
    local deadline=$(( $(date +%s) + $1 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        pg_is_up && return 0
        sleep 2
    done
    return 1
}

wait_url_200() { # URL TIMEOUT — poll an arbitrary URL until it answers 200
    local url="$1" deadline=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url")" = "200" ] && return 0
        sleep 2
    done
    return 1
}

# ─── Checks (the verdict ledger) ──────────────────────────────────────────
_check_record() { # ok(0/1) DESC DETAIL
    if [ "$1" = "0" ]; then
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        printf '    PASS  %s\n' "$2"
    else
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        FAILED_DETAILS="${FAILED_DETAILS}${2} (${3})
"
        printf '    FAIL  %s — %s\n' "$2" "$3"
    fi
}

skip_check() { # DESC REASON — record a leg that could not run
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
    printf '    SKIP  %s — %s\n' "$1" "$2"
}

check_eq() { # DESC EXPECTED ACTUAL
    [ "$DRY_RUN" = "1" ] && { printf '  [dry-run] check: %s (expect %s)\n' "$1" "$2"; CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)); return 0; }
    if [ "$3" = "$2" ]; then _check_record 0 "$1"; else _check_record 1 "$1" "expected '$2', got '$3'"; fi
}

check_in() { # DESC "ALLOWED…" ACTUAL — ACTUAL must be one of the words
    [ "$DRY_RUN" = "1" ] && { printf '  [dry-run] check: %s (expect one of %s)\n' "$1" "$2"; CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)); return 0; }
    case " $2 " in
        *" $3 "*) _check_record 0 "$1" ;;
        *)        _check_record 1 "$1" "expected one of [$2], got '$3'" ;;
    esac
}

check_contains() { # DESC HAYSTACK NEEDLE
    [ "$DRY_RUN" = "1" ] && { printf '  [dry-run] check: %s (contains %s)\n' "$1" "$3"; CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)); return 0; }
    case "$2" in
        *"$3"*) _check_record 0 "$1" ;;
        *)      _check_record 1 "$1" "'$3' not found" ;;
    esac
}

check_service_running() { # DESC SERVICE
    [ "$DRY_RUN" = "1" ] && { printf '  [dry-run] check: %s\n' "$1"; CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)); return 0; }
    if compose_base ps --status running --services 2>/dev/null | grep -qx "$2"; then
        _check_record 0 "$1"
    else
        _check_record 1 "$1" "service '$2' not running"
    fi
}

check_cmd() { # DESC CMD… — pass iff the command exits 0
    local desc="$1"; shift
    [ "$DRY_RUN" = "1" ] && { printf '  [dry-run] check: %s\n' "$desc"; CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)); return 0; }
    if "$@" >/dev/null 2>&1; then _check_record 0 "$desc"; else _check_record 1 "$desc" "command failed: $*"; fi
}

# ─── Steady state ─────────────────────────────────────────────────────────
# Quick mode is health-only. The business-flow legs (a real end-to-end
# canary, tenancy sweeps) come from the optional product hook — see the
# bottom of this file and lib/steady-state.sh.example.
steady_state() { # LABEL
    local label="$1"
    check_eq "$label: /livez answers 200" 200 "$(http_code /livez)"
    check_eq "$label: /readyz answers 200 (the real health signal)" 200 "$(http_code /readyz)"
}

canary_available() { declare -f flow_canary >/dev/null 2>&1; }

run_flow_canary() { # LABEL — foreground business-flow canary (FULL mode)
    local label="$1"
    if canary_available; then
        check_cmd "$label: business-flow canary" flow_canary "$label"
    else
        note "no flow_canary hook — see lib/steady-state.sh.example"
        skip_check "$label: business-flow canary" "lib/steady-state.sh not installed"
    fi
}

CANARY_BG_PID=""
launch_bg_canary() { # LOGFILE — background canary for midwrite/kill class
    CANARY_BG_PID=""
    if [ "$DRY_RUN" = "1" ]; then
        printf '  [dry-run] launch background flow canary\n'
        return 0
    fi
    if [ "$CHAOS_FULL" != "1" ]; then
        note "canary leg not requested (pass --full) — fault runs against health polling only"
        return 0
    fi
    if ! canary_available; then
        note "no flow_canary hook — background canary skipped"
        skip_check "background flow canary" "lib/steady-state.sh not installed"
        return 0
    fi
    note "launching background flow canary (log: $1)"
    flow_canary "background" >"$1" 2>&1 &
    CANARY_BG_PID=$!
}

tenancy_sweep_available() { declare -f tenancy_sweep >/dev/null 2>&1; }

run_tenancy_sweep() { # recovery leg for tenancy experiments (FULL mode)
    if tenancy_sweep_available; then
        check_cmd "tenancy sweep passes at recovery" tenancy_sweep
    else
        note "no tenancy_sweep hook — sweep leg skipped"
        skip_check "tenancy sweep at recovery" "lib/steady-state.sh not installed"
    fi
}

# ─── Stack preconditions ──────────────────────────────────────────────────
stack_up() { # 0 iff the dev stack answers
    [ "$(http_code /livez 5)" = "200" ]
}

require_stack() {
    [ "$DRY_RUN" = "1" ] && return 0
    if ! stack_up; then
        log "  dev stack not reachable at $SERVICE_BASE_URL — start it first:"
        log "    metaphor docker up --env dev"
        return 1
    fi
}

# ─── Product steady-state hook (optional) ─────────────────────────────────
# A product workspace may install lib/steady-state.sh (start from
# lib/steady-state.sh.example) defining any of:
#   flow_canary LABEL — one real business-flow probe; exit 0 = pass.
#                       Run foreground (verdict leg) and background (midwrite
#                       observation); keep it self-contained and idempotent.
#   tenancy_sweep     — tenancy-fence probes for the recovery leg; exit 0 = pass.
# The file must only DEFINE functions (it is sourced at kit startup).
# Without the hook, the kit runs health-only steady state and the
# canary/sweep legs record as SKIP — a fresh workspace is still fully
# runnable, just shallower.
if [ -f "$CHAOS_LIB_DIR/steady-state.sh" ]; then
    . "$CHAOS_LIB_DIR/steady-state.sh"
fi
