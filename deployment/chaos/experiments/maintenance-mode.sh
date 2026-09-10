# Experiment: maintenance-mode
#
# Fault        : the service is recreated with MAINTENANCE_ADMIN_TOKEN set
#                (transient compose override — the token is closed/501 by
#                default), then the maintenance gate is switched ON via
#                POST /maintenance. Recreate class: slow, restarts the dev
#                service — coordinate before running.
# Hypothesis   : gated paths answer 503 with the x-service-status:
#                maintenance header; the allow-listed probes (/health,
#                /livez, /readyz, /maintenance/*) stay reachable; the gate
#                switches off cleanly and the override is withdrawn.
# Blast radius : dev stack; service container env + runtime gate state; no
#                volumes touched.
#
# Knob: CHAOS_GATED_PATH — any protected path outside the gate's allow-list
# (default /api/v1). It must NOT 503 while the gate is off.

EXPERIMENT_NAME="maintenance-mode"
FAULT="maintenance gate switched ON via POST /maintenance (token via compose override)"
HYPOTHESIS="gated paths 503 with x-service-status: maintenance; probes stay reachable; clean off-toggle"
BLAST_RADIUS="dev stack, $SERVICE_NAME env + gate state; SLOW (container recreate)"

OVERRIDE_FILE="$OVERRIDES_DIR/maintenance-token.yaml"
ADMIN_TOKEN="chaos-dev-maintenance-token"
GATED_PATH="${CHAOS_GATED_PATH:-/api/v1}"   # any protected path outside allow_paths

gate_set() { # ENABLED(0|1) — returns the API status code of the toggle call
    local enabled="$1" json_val
    # The toggle contract is a JSON boolean (Option<bool> on the framework
    # side); a shell 1/0 interpolated raw becomes a JSON number and the
    # handler answers 422.
    if [ "$enabled" = "1" ]; then json_val=true; else json_val=false; fi
    if [ "$DRY_RUN" = "1" ]; then
        printf '  [dry-run] POST /maintenance {\"enabled\":%s} (Bearer token)\n' "$json_val"
        printf '200'
        return 0
    fi
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "$SERVICE_BASE_URL/maintenance" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H 'Content-Type: application/json' \
        -d "{\"enabled\":$json_val}"
}

inject() {
    run compose_ov "$OVERRIDE_FILE" up -d "$SERVICE_NAME"
    mark_injected
    check_cmd "service ready with the admin token mounted" wait_readyz "$WAIT_SLOW_TIMEOUT"
    check_eq "gate ON accepted (200 + snapshot)" 200 "$(gate_set 1)"
}

during_fault() {
    check_eq "gated path answers 503" 503 "$(http_code "$GATED_PATH" 10)"
    check_eq "503 carries x-service-status: maintenance" "maintenance" \
        "$(http_header "$GATED_PATH" x-service-status 10)"
    check_eq "allow-listed /health still reachable" 200 "$(http_code /health 10)"
    check_eq "allow-listed /livez still reachable" 200 "$(http_code /livez 10)"
    check_eq "allow-listed /readyz still reachable" 200 "$(http_code /readyz 10)"
    check_eq "allow-listed /maintenance/status reachable" 200 "$(http_code /maintenance/status 10)"
}

restore() {
    check_eq "gate OFF accepted (200 + snapshot)" 200 "$(gate_set 0)"
    check_in "gated path back to normal (auth answer, not 503-maintenance)" \
        "401 403 404" "$(http_code "$GATED_PATH" 10)"
    # Withdraw the override env entirely.
    run compose_base up -d "$SERVICE_NAME"
    check_cmd "service recreated without the override" wait_readyz "$WAIT_SLOW_TIMEOUT"
}
