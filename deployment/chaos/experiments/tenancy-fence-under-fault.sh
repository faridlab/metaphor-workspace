# Experiment: tenancy-fence-under-fault
#
# Fault        : the control plane is stopped while the tenancy surface is
#                exercised. In dev, tenant resolution runs in-process
#                (TENANT_ALLOW_HEADER_OVERRIDE=true, x-tenant-slug header);
#                this experiment proves the fence stays CLOSED when the
#                platform tier is gone.
# Hypothesis   : with the control plane down, an API request WITHOUT a
#                tenant slug is still refused as unknown-tenant (404 — never
#                5xx), a request WITH the resident slug proceeds to the
#                normal auth answer (401 — never 5xx), and the resident
#                tenant's health stays green. FULL mode additionally runs
#                the workspace's tenancy sweep at recovery (needs the
#                lib/steady-state.sh hook).
# Blast radius : dev stack; control-plane; no volumes touched.
#
# Optional-service experiment: skipped when the compose runs no control
# plane. Knobs: CHAOS_TENANCY_API_PATH (a mounted module route),
# CHAOS_RESIDENT_SLUG (falls back to TENANT_ZERO_SLUG in deployment/.env.dev
# or "dev").

EXPERIMENT_NAME="tenancy-fence-under-fault"
FAULT="control-plane stopped while the tenant-resolution surface is probed"
HYPOTHESIS="fence stays closed under platform-tier loss: unknown tenant → 404, resident tenant → normal auth, never 5xx/fail-open"
BLAST_RADIUS="dev stack, $CONTROL_PLANE_SERVICE only, no volume changes"

require_service "$CONTROL_PLANE_SERVICE" "tenancy fence needs the platform tier to lose"

API_PATH="${CHAOS_TENANCY_API_PATH:-/api/v1}"
RESIDENT_SLUG="${CHAOS_RESIDENT_SLUG:-$(env_value TENANT_ZERO_SLUG)}"
RESIDENT_SLUG="${RESIDENT_SLUG:-dev}"

during_fault() {
    # Unknown tenant (no slug) must be REFUSED, not error out — 404 is the
    # fail-closed answer; a 500 here would mean tenant resolution degraded
    # open or crashed.
    local no_slug with_slug
    no_slug="$(http_code_h "$API_PATH" x-tenant-slug __absent__ 10)"
    # (the __absent__ header value is never sent — see http_code_h; blank
    #  would still send the header, so the helper drops it for this marker)
    check_eq "unknown tenant refused (404 unknown_tenant, not 5xx)" 404 "$no_slug"
    with_slug="$(http_code_h "$API_PATH" x-tenant-slug "$RESIDENT_SLUG" 10)"
    check_in "resident slug proceeds to the auth answer (401/403/404 — never 5xx)" \
        "401 403 404" "$with_slug"
    check_eq "resident tenant health stays green" 200 "$(http_code /readyz 10)"
    check_service_running "service container stays up" "$SERVICE_NAME"
}

inject() {
    run compose_base stop "$CONTROL_PLANE_SERVICE"
    mark_injected
}

restore() {
    run compose_base start "$CONTROL_PLANE_SERVICE"
    check_cmd "control-plane container running again" wait_service_running "$CONTROL_PLANE_SERVICE" 90
    check_cmd "control-plane /health answers again" wait_url_200 "$CONTROL_PLANE_BASE_URL/health" 120
    check_cmd "service ready" wait_readyz "$WAIT_HTTP_TIMEOUT"
}

recovery_checks() {
    steady_state recovery
    if [ "$CHAOS_FULL" = "1" ]; then
        run_tenancy_sweep
    fi
}
