# Experiment: pool-exhaustion
#
# Fault        : postgres server connections are filled to capacity with
#                held `pg_sleep` sessions (run inside the postgres
#                container — no host psql dependency).
# Hypothesis   : the service answers controlled errors (5xx within the
#                request timeout, never an unbounded hang), does not leak
#                into a crash-loop, and fully recovers once the sleeper
#                sessions are terminated.
# Blast radius : dev stack only; postgres connection slots (transient —
#                sessions are pg_terminate_backend'd in restore; the abort
#                trap runs the same termination).

EXPERIMENT_NAME="pool-exhaustion"
FAULT="postgres connections filled with held pg_sleep(600) sessions"
HYPOTHESIS="controlled 5xx under pool pressure (no hang, no crash-loop); clean recovery after the sleepers are terminated"
BLAST_RADIUS="dev stack, postgres connection slots only"

terminate_sleepers() {
    pg_scalar "SELECT count(*) FROM (
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE query LIKE '%pg_sleep%' AND pid <> pg_backend_pid()
    ) t" >/dev/null 2>&1 || true
}

inject() {
    mark_injected
    if [ "$DRY_RUN" = "1" ]; then
        note "would: read max_connections + superuser_reserved_connections, then open"
        note "       pg_sleep(600) sessions inside the postgres container until"
        note "       pg_stat_activity count reaches capacity minus reserved slots."
        return 0
    fi
    local max_conn reserved target count opened=0
    max_conn="$(pg_scalar 'SHOW max_connections')"
    reserved="$(pg_scalar 'SHOW superuser_reserved_connections')"
    target=$(( ${max_conn:-100} - ${reserved:-3} - 1 ))
    note "max_connections=${max_conn:-?} reserved=${reserved:-?} → filling to ~$target sessions"
    while :; do
        count="$(pg_scalar 'SELECT count(*) FROM pg_stat_activity')"
        [ "${count:-0}" -ge "$target" ] && break
        [ "$opened" -ge 130 ] && break   # hard cap, well above any default
        compose_base exec -T -d postgres psql -U "$PG_USER" \
            -d "$PG_DB" \
            -c 'SELECT pg_sleep(600)' >/dev/null 2>&1
        opened=$((opened + 1))
    done
    note "opened $opened sleeper sessions (pg_stat_activity now at ${count:-?})"
}

during_fault() {
    check_service_running "service container stays up under pool pressure" "$SERVICE_NAME"
    check_in "controlled degradation: /readyz answers 5xx/503 (or stays honest), bounded by --max-time" \
        "503 500 502 504 000 200" "$(http_code /readyz 15)"
}

restore() {
    if [ "$DRY_RUN" = "1" ]; then
        note "would: pg_terminate_backend every pg_sleep session, then wait for readiness."
        return 0
    fi
    terminate_sleepers
    check_cmd "sleeper sessions terminated" bash -c \
        "[ \"\$(pg_scalar 'SELECT count(*) FROM pg_stat_activity WHERE query LIKE '\''%pg_sleep%'\'' AND pid <> pg_backend_pid()')\" = \"0\" ]"
    check_cmd "service ready again after pool relief" wait_readyz "$WAIT_HTTP_TIMEOUT"
}
