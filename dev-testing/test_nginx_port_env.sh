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
check "preflight.sh reads NGINX_HTTP_PORT" "1" "$(grep -c '^add_nginx_port NGINX_HTTP_PORT ' "${PROJECT_ROOT}/preflight.sh")"
check "preflight.ps1 reads NGINX_HTTP_PORT" "1" "$(grep -c '^Add-NginxPort "NGINX_HTTP_PORT"' "${PROJECT_ROOT}/preflight.ps1")"

# preflight.sh as a whole pulls and removes a Docker image and pings the
# internet, so it is not run here. Instead the real nginx-port block (load_env_var
# through the add_nginx_port calls) is cut out of the script and run against
# temp env files, with fail() stubbed to print its message.
preflight_nginx_output() { # env file contents
    local envfile="$TMP/preflight.env"
    printf '%s\n' "$1" >"$envfile"
    ENV_FILE="$envfile" bash -c '
        fail() { echo "FAIL: $1"; }
        source <(sed -n "/^load_env_var() {/,/^}/p" "$0")
        source <(sed -n "/^declare -A PORTS=(/,/^add_nginx_port NGINX_HTTPS_PORT/p" "$0")
        for p in "${!PORTS[@]}"; do echo "PORT $p ${PORTS[$p]}"; done
    ' "${PROJECT_ROOT}/preflight.sh" 2>&1
}
has() { grep -c -- "$2" <<<"$1" || true; }

out="$(preflight_nginx_output 'NGINX_HTTP_PORT=abc')"
check "preflight.sh refuses NGINX_HTTP_PORT=abc" "1" "$(has "$out" "NGINX_HTTP_PORT must be a port number (1-65535), got 'abc'")"
check "preflight.sh falls back to 80 after a bad value" "1" "$(has "$out" 'PORT 80 nginx (HTTP)')"
out="$(preflight_nginx_output 'NGINX_HTTPS_PORT=70000')"
check "preflight.sh refuses NGINX_HTTPS_PORT=70000" "1" "$(has "$out" "NGINX_HTTPS_PORT must be a port number (1-65535), got '70000'")"
out="$(preflight_nginx_output 'NGINX_HTTP_PORT=8080')"
check "preflight.sh flags NGINX_HTTP_PORT=8080 colliding with qBittorrent" "1" "$(has "$out" 'nginx (HTTP) port 8080 collides with qBittorrent WebUI')"
out="$(preflight_nginx_output $'NGINX_HTTP_PORT=8088\nNGINX_HTTPS_PORT=8088')"
check "preflight.sh flags both nginx ports being equal" "1" "$(has "$out" 'nginx (HTTPS) port 8088 collides with nginx (HTTP)')"
out="$(preflight_nginx_output $'NGINX_HTTP_PORT=8088\nNGINX_HTTPS_PORT=8443')"
check "preflight.sh accepts 8088 and 8443 without complaint" "0" "$(has "$out" 'FAIL:')"
check "preflight.sh lists 8088 and 8443 as nginx" "2" "$(has "$out" 'PORT 8[04][84][83] nginx')"
check "preflight.ps1 validates the port range" "1" "$(grep -c '\-le 65535' "${PROJECT_ROOT}/preflight.ps1")"
check "preflight.ps1 checks for an existing key" "1" "$(grep -c 'PortsToCheck.ContainsKey' "${PROJECT_ROOT}/preflight.ps1")"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
