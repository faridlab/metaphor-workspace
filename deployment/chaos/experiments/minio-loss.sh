# Experiment: minio-loss
#
# Fault        : the minio container is stopped (object storage vanishes).
# Hypothesis   : the service does not crash-loop; storage-bound flows fail
#                closed with typed errors; steady state returns once minio
#                is back.
# Blast radius : dev stack only; minio; no volumes touched.

EXPERIMENT_NAME="minio-loss"
FAULT="docker compose stop minio (dev stack)"
HYPOTHESIS="no crash-loop; storage-bound flows fail closed; steady state returns after minio restarts"
BLAST_RADIUS="dev stack, minio only, no volume changes"

inject() {
    run compose_base stop minio
    mark_injected
}

during_fault() {
    check_service_running "service container stays up under storage loss" "$SERVICE_NAME"
    check_in "honest health while storage is down (200 or 5xx — never a hang)" \
        "200 503 500 502 504 000" "$(http_code /readyz 10)"
}

restore() {
    run compose_base start minio
    check_cmd "minio container running again" wait_service_running minio 90
    check_cmd "service ready again" wait_readyz "$WAIT_HTTP_TIMEOUT"
}
