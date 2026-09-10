# Experiment: control-plane-loss
#
# Fault        : the control-plane container is stopped (tenant registry /
#                on-demand-TLS authority unavailable).
# Hypothesis   : the RESIDENT tenant keeps serving — /readyz stays 200 and
#                the API keeps answering — because tenant resolution for an
#                already-resident database does not depend on the control
#                plane. Tenancy never fails open.
# Blast radius : dev stack only; control-plane; no volumes touched.
#
# Optional-service experiment: a workspace whose compose does not run a
# control plane skips it (require_service).

EXPERIMENT_NAME="control-plane-loss"
FAULT="docker compose stop $CONTROL_PLANE_SERVICE (dev stack)"
HYPOTHESIS="resident tenant keeps serving (/readyz 200, API answers); control-plane unreachable; no fail-open"
BLAST_RADIUS="dev stack, $CONTROL_PLANE_SERVICE only, no volume changes"

require_service "$CONTROL_PLANE_SERVICE" "this workspace runs a single-service stack"

inject() {
    run compose_base stop "$CONTROL_PLANE_SERVICE"
    mark_injected
}

during_fault() {
    check_eq "resident tenant unaffected: /readyz stays 200" 200 "$(http_code /readyz 10)"
    check_eq "resident tenant unaffected: /livez stays 200" 200 "$(http_code /livez 10)"
    check_eq "control-plane is actually down (connection refused)" 000 \
        "$(http_code /health 5 "$CONTROL_PLANE_BASE_URL")"
    check_service_running "service container stays up" "$SERVICE_NAME"
}

restore() {
    run compose_base start "$CONTROL_PLANE_SERVICE"
    check_cmd "control-plane container running again" wait_service_running "$CONTROL_PLANE_SERVICE" 90
    check_cmd "control-plane /health answers again" wait_url_200 "$CONTROL_PLANE_BASE_URL/health" 120
    check_cmd "service ready" wait_readyz "$WAIT_HTTP_TIMEOUT"
}
