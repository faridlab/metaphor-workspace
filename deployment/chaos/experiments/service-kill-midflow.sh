# Experiment: service-kill-midflow
#
# Fault        : the service is SIGKILLed (docker compose kill) while a
#                business-flow canary is in flight (FULL mode).
# Hypothesis   : the restart policy revives the container, no wedged state
#                survives, and steady state (plus a fresh journey, FULL
#                mode) returns within the warm-restart window.
# Blast radius : dev stack only; the service process; its own probe
#                footprint. Volumes untouched (a wiped cargo target volume
#                would turn this into a ~50-minute rebuild — never allowed).

EXPERIMENT_NAME="service-kill-midflow"
FAULT="docker compose kill $SERVICE_NAME (SIGKILL, restart policy revives it)"
HYPOTHESIS="container revives, state stays consistent, steady state returns within the warm-restart window"
BLAST_RADIUS="dev stack, $SERVICE_NAME process only, no volume changes"

CANARY_BG_LOG="$(mktemp -t chaos-kill.XXXXXX)"

inject() {
    launch_bg_canary "$CANARY_BG_LOG"
    if [ -n "$CANARY_BG_PID" ]; then
        run_sh "sleep 5"   # let the journey get in flight
    fi
    run compose_base kill "$SERVICE_NAME"
    mark_injected
}

during_fault() {
    if [ -n "$CANARY_BG_PID" ]; then
        wait "$CANARY_BG_PID"
        note "background canary exit code: $? (OBSERVATION — the recovery rerun is the verdict leg)"
    fi
    check_service_running "container revived by restart policy" "$SERVICE_NAME"
}

restore() {
    # The fault withdrew itself via the restart policy; this phase waits out
    # the warm restart / watch re-run.
    run compose_base start "$SERVICE_NAME"
    check_cmd "service ready again within warm-restart window" wait_readyz "$WAIT_SLOW_TIMEOUT"
}

recovery_checks() {
    steady_state recovery
    if [ "$CHAOS_FULL" = "1" ]; then
        run_flow_canary "recovery"
    fi
}
