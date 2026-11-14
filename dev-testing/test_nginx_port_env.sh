#!/bin/bash
# =============================================================================
# Simplarr — nginx host ports from NGINX_HTTP_PORT / NGINX_HTTPS_PORT
# =============================================================================
# nginx publishes on 80/443 unless the environment sets NGINX_HTTP_PORT /
# NGINX_HTTPS_PORT (for a host where a shared reverse proxy owns 80/443).
# Renders the compose files with `docker compose config`; no containers start.
# The project's own .env is ignored (--env-file /dev/null).
#
# Usage:  ./dev-testing/test_nginx_port_env.sh
# Exit:   0 all passed, 1 any failed
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PUID=1000 PGID=1000 TZ=UTC DOCKER_CONFIG="$TMP/config" DOCKER_MEDIA="$TMP/media"

PASS=0
FAIL=0
check() { # description expected actual
    if [[ "$2" == "$3" ]]; then
        echo "  PASS  $1"; PASS=$((PASS + 1))
    else
        echo "  FAIL  $1: expected [$2], got [$3]"; FAIL=$((FAIL + 1))
    fi
}

ports_of() { # compose file, then any VAR=value pairs
    local file=$1
    shift
    env "$@" docker compose --env-file /dev/null -f "${PROJECT_ROOT}/${file}" config --format json 2>/dev/null |
        jq -r '[.services.nginx.ports[] | "\(.published):\(.target)"] | join(" ")'
}

for file in docker-compose-pi.yml docker-compose-unified.yml; do
    check "${file}: nginx defaults to 80 and 443" "80:80 443:443" "$(ports_of "$file")"
    check "${file}: nginx follows NGINX_HTTP_PORT / NGINX_HTTPS_PORT" "8088:80 8443:443" \
        "$(ports_of "$file" NGINX_HTTP_PORT=8088 NGINX_HTTPS_PORT=8443)"
done
check "preflight.sh reads NGINX_HTTP_PORT" "1" "$(grep -c 'load_env_var NGINX_HTTP_PORT' "${PROJECT_ROOT}/preflight.sh")"
check "preflight.ps1 reads NGINX_HTTP_PORT" "1" "$(grep -c 'Get-EnvVariable "NGINX_HTTP_PORT"' "${PROJECT_ROOT}/preflight.ps1")"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
