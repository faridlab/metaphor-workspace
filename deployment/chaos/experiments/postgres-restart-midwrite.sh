# Experiment: postgres-restart-midwrite
#
# Fault        : postgres is stopped and started again while a business-flow
#                canary is in flight (FULL mode) or while health is polled
#                (quick mode).
# Hypothesis   : a mid-flight journey either completes or fails cleanly — no
#                lost/duplicated writes, no wedged state — and a fresh run
#                after recovery passes, proving the data path intact.
# Blast radius : dev stack only; postgres; the canary's own probe footprint.
# Restore      : `compose start postgres` (abort trap covers the window).

EXPERIMENT_NAME="postgres-restart-midwrite"
FAULT="postgres stopped + restarted while a canary flow runs"
HYPOTHESIS="mid-flight flow completes or fails cleanly; a recovery rerun passes and steady state returns"
BLAST_RADIUS="dev stack, postgres, canary probe footprint only"

CANARY_BG_LOG="$(mktemp -t chaos-midwrite.XXXXXX)"

inject() {
    launch_bg_canary "$CANARY_BG_LOG"
    mark_injected
    run compose_base stop postgres
    run_sh "sleep 3"   # let the fault bite the in-flight flow
    run compose_base start postgres
}

during_fault() {
    check_cmd "postgres back up after restart" wait_pg_up 90
    check_cmd "service ready again" wait_readyz "$WAIT_HTTP_TIMEOUT"
    if [ -n "$CANARY_BG_PID" ]; then
        wait "$CANARY_BG_PID"
        local rc=$?
        note "background canary exit code: $rc (failure here is an OBSERVATION — the verdict is the recovery rerun)"
    fi
}

restore() {
    # The fault withdrew itself when postgres restarted; confirm the stack.
    run compose_base start postgres
    check_cmd "postgres accepts connections" wait_pg_up 90
    check_cmd "service ready" wait_readyz "$WAIT_HTTP_TIMEOUT"
}

recovery_checks() {
    steady_state recovery
    if [ "$CHAOS_FULL" = "1" ]; then
        # The verdict leg: a FRESH journey over the restarted database.
        run_flow_canary "recovery"
    fi
}
