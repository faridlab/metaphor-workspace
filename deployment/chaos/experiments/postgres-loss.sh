# Experiment: postgres-loss
#
# Fault        : the postgres container is stopped (the database vanishes).
# Hypothesis   : the API degrades honestly — typed 5xx or refused connections,
#                never a hang or a lying 200 — and after postgres returns the
#                pool reconnects and steady state is fully restored.
# Blast radius : dev stack only; one dependency (postgres); no volumes touched.
# Restore      : `compose start postgres` (the abort trap does the same).

EXPERIMENT_NAME="postgres-loss"
FAULT="docker compose stop postgres (dev stack)"
HYPOTHESIS="API answers typed 5xx/refused (no hang, no crash-loop); pool reconnects and steady state returns after postgres restarts"
BLAST_RADIUS="dev stack, postgres only, no volume changes"

inject() {
    run compose_base stop postgres
    mark_injected
}

during_fault() {
    # curl --max-time bounds every call, so completing at all proves no hang;
    # 000 = connection refused/timeout, both honest degradations.
    check_in "degraded: /readyz is 503/refused (or 5xx), not a lying 200" \
        "503 500 502 504 000" "$(http_code /readyz 10)"
    check_in "degraded: /livez honest (5xx/refused accepted)" \
        "503 500 502 504 000 200" "$(http_code /livez 10)"
    check_service_running "service container stays up under DB loss (no panic)" "$SERVICE_NAME"
}

restore() {
    run compose_base start postgres
    check_cmd "postgres accepts connections again" wait_pg_up 90
    check_cmd "service ready again (pool reconnected)" wait_readyz "$WAIT_HTTP_TIMEOUT"
}
