#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

postcheck_port="${CUBE_PROXY_HTTP_PORT:-80}"
postcheck_grpc_port="${CUBE_PROXY_GRPC_PORT:-9090}"
admin_port="${CUBE_PROXY_ADMIN_PORT:-8082}"
admin_url="${CUBE_PROXY_ADMIN_URL:-http://${CUBE_SANDBOX_NODE_IP:-127.0.0.1}:${admin_port}}"
admin_health_url="${admin_url%/}/admin/healthz"
admin_token="${CUBE_ADMIN_TOKEN:-}"
postcheck_retries="${CUBE_PROXY_POSTCHECK_RETRIES:-30}"
postcheck_delay="${CUBE_PROXY_POSTCHECK_DELAY:-2}"
deprecated_host_port="${CUBE_PROXY_HOST_PORT:-}"

if [[ -n "${deprecated_host_port}" ]]; then
  log "CUBE_PROXY_HOST_PORT is deprecated and ignored; set CUBE_PROXY_HTTP_PORT to change the post-start check port"
fi

log "checking cube-proxy HTTP tcp port ${postcheck_port}"
wait_for_tcp_port "${postcheck_port}" "${postcheck_retries}" "${postcheck_delay}" || die "cube-proxy HTTP tcp port not ready: ${postcheck_port}"
log "checking cube-proxy gRPC tcp port ${postcheck_grpc_port}"
wait_for_tcp_port "${postcheck_grpc_port}" "${postcheck_retries}" "${postcheck_delay}" || die "cube-proxy gRPC tcp port not ready: ${postcheck_grpc_port}"

require_cmd curl
log "checking cube-proxy advertised admin endpoint ${admin_health_url}"
if [[ -n "${admin_token}" ]]; then
  wait_for_http_header "${admin_health_url}" "${postcheck_retries}" "${postcheck_delay}" \
    "X-Cube-Admin-Token" "${admin_token}" \
    || die "cube-proxy advertised admin endpoint not ready: ${admin_health_url} (check CUBE_PROXY_ADMIN_LISTEN/CUBE_PROXY_ADMIN_URL/CUBE_PROXY_ADMIN_PORT, rendered nginx.conf, and 'docker logs cube-proxy')"
else
  wait_for_http "${admin_health_url}" "${postcheck_retries}" "${postcheck_delay}" \
    || die "cube-proxy advertised admin endpoint not ready: ${admin_health_url} (check CUBE_PROXY_ADMIN_LISTEN/CUBE_PROXY_ADMIN_URL/CUBE_PROXY_ADMIN_PORT, rendered nginx.conf, and 'docker logs cube-proxy')"
fi
