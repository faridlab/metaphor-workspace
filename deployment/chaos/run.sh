#!/usr/bin/env bash
# Chaos experiment driver — __project__ dev stack. See docs/chaos/README.md.
#
# Usage:
#   deployment/chaos/run.sh [options] [experiment … | all | list]
#
# Options:
#   --dry-run   print every action and check, touch nothing
#   --full      CHAOS_FULL=1 — add the flow-canary legs (business-flow
#               canary + tenancy sweeps; slower, needs the steady-state hook)
#
# Experiments run SERIALLY. Each experiment gets its own runlog under
# deployment/chaos/runlogs/.
# Exit status: non-zero if any experiment failed (chaos_exit= line).

set -u

CHAOS_DRIVER_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$CHAOS_DRIVER_DIR/lib/common.sh"

EXPERIMENTS_DIR="$CHAOS_DIR/experiments"

# Catalog order — dependency-faults first, recreate-class (slow) later.
CATALOG="postgres-loss postgres-restart-midwrite minio-loss control-plane-loss \
service-kill-midflow pool-exhaustion secret-fail-closed maintenance-mode \
tenancy-fence-under-fault"

usage() {
    cat <<EOF
__project__ chaos kit — dev stack fault injection

usage: run.sh [--dry-run] [--full] [experiment … | all | list]

catalog (run serially, in this order):
EOF
    local name
    for name in $CATALOG; do
        printf '  %s\n' "$name"
    done
    printf '\nrun.sh list   — same, one per line\n'
}

list_experiments() {
    local name
    for name in $CATALOG; do printf '%s\n' "$name"; done
}

# ─── One experiment, isolated in a subshell (its own EXIT trap / ledger) ──
run_experiment() { # NAME → 0 pass, 1 fail, 2 skipped
    local name="$1"
    local script="$EXPERIMENTS_DIR/$name.sh"
    local log_file="$RUNLOGS_DIR/$(date +%F)-$name.log"

    if [ ! -f "$script" ]; then
        log "!! no such experiment: $name (see run.sh list)"
        return 2
    fi
    mkdir -p "$RUNLOGS_DIR"

    # Dry-runs print to the console only — runlogs are the evidence trail and
    # must never contain a plan that was never executed. `| cat` keeps the
    # pipeline shape so PIPESTATUS[0] stays the subshell's status.
    local sink=(cat)
    [ "$DRY_RUN" != "1" ] && sink=(tee -a "$log_file")

    (
        # Reset the per-experiment ledger (globals from common.sh).
        INJECTED=0 RESTORED=0
        CHECKS_PASSED=0 CHECKS_FAILED=0 CHECKS_SKIPPED=0 FAILED_DETAILS=""

        . "$script"

        log "════════════════════════════════════════════════════════════════"
        log "experiment : $EXPERIMENT_NAME"
        log "fault      : $FAULT"
        log "hypothesis : $HYPOTHESIS"
        log "blast radius: $BLAST_RADIUS"
        log "mode       : dry_run=$DRY_RUN full=$CHAOS_FULL"
        log "════════════════════════════════════════════════════════════════"

        if ! require_stack; then
            log "SKIP: $EXPERIMENT_NAME — dev stack unreachable"
            exit 2
        fi

        # Defaults; an experiment file may define its own.
        if ! declare -f baseline_checks >/dev/null; then
            baseline_checks() {
                steady_state baseline
                [ "$CHAOS_FULL" = "1" ] && run_flow_canary baseline
                return 0
            }
        fi
        if ! declare -f recovery_checks >/dev/null; then
            recovery_checks() {
                steady_state recovery
                [ "$CHAOS_FULL" = "1" ] && run_flow_canary recovery
                return 0
            }
        fi

        log "── phase 1/5: baseline (must be green before injecting)"
        baseline_checks

        if [ "$CHECKS_FAILED" -gt 0 ]; then
            log "ABORT: baseline is not green — not injecting anything."
            exit 1
        fi

        log "── phase 2/5: inject"
        inject

        log "── phase 3/5: observe under fault"
        if declare -f during_fault >/dev/null; then
            during_fault
        else
            note "(no during-fault checks defined)"
        fi

        log "── phase 4/5: restore"
        restore
        RESTORED=1

        log "── phase 5/5: recovery (steady state must return)"
        recovery_checks

        log "──────────────────────────────────────────────────────────────"
        if [ "$CHECKS_FAILED" -gt 0 ]; then
            log "VERDICT: FAIL — $EXPERIMENT_NAME"
            log "failures:"
            printf '%s' "$FAILED_DETAILS" | sed 's/^/    - /'
            log "rc=1 passed=$CHECKS_PASSED failed=$CHECKS_FAILED skipped=$CHECKS_SKIPPED"
            log "(file a tracker issue referencing $log_file)"
            exit 1
        fi
        log "VERDICT: PASS — $EXPERIMENT_NAME"
        log "rc=0 passed=$CHECKS_PASSED failed=$CHECKS_FAILED skipped=$CHECKS_SKIPPED"
        exit 0
    ) 2>&1 | "${sink[@]}"

    # The subshell's status, not the sink's (a bare $? would report the pipe tail).
    return "${PIPESTATUS[0]}"
}

# ─── Arg parsing ──────────────────────────────────────────────────────────
ARGS=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --full)    CHAOS_FULL=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         ARGS="$ARGS $arg" ;;
    esac
done

[ -z "${ARGS:-}" ] && { usage; exit 0; }

SELECTED=""
for arg in $ARGS; do
    case "$arg" in
        list) list_experiments; exit 0 ;;
        all)  SELECTED="$SELECTED $CATALOG" ;;
        *)    SELECTED="$SELECTED $arg" ;;
    esac
done

# ─── Drive ────────────────────────────────────────────────────────────────
TOTAL_RUN=0 TOTAL_FAIL=0 TOTAL_SKIP=0
FAILED_NAMES=""

for name in $SELECTED; do
    run_experiment "$name"
    rc=$?
    TOTAL_RUN=$((TOTAL_RUN + 1))
    case $rc in
        1) TOTAL_FAIL=$((TOTAL_FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $name" ;;
        2) TOTAL_SKIP=$((TOTAL_SKIP + 1)) ;;
    esac
done

log ""
log "chaos summary: run=$TOTAL_RUN failed=$TOTAL_FAIL skipped=$TOTAL_SKIP"
[ -n "$FAILED_NAMES" ] && log "failed:$FAILED_NAMES"
if [ "$TOTAL_FAIL" -gt 0 ]; then
    log "chaos_exit=1"
    exit 1
fi
log "chaos_exit=0"
exit 0
