#!/bin/bash
# =============================================================================
# Homepage Config Injection Tests
# =============================================================================
# Verifies that /config.json injection is properly implemented in the homepage:
#
#   Structural:
#     - homepage/config.json.template exists with all required port placeholders
#     - homepage/Dockerfile references an entrypoint script
#     - The entrypoint script uses envsubst to render config.json at startup
#     - dashboard.js fetches /config.json and falls back to hardcoded defaults
#     - status.js fetches /config.json and falls back to hardcoded defaults
#     - Fallback defaults in JS match the current canonical port values
#     - docker-compose-unified.yml passes port env vars to the homepage service
#     - docker-compose-pi.yml passes port env vars to the homepage service
#
#   Integration (requires Docker):
#     - Container started with custom port env vars serves config.json with
#       those values at /config.json
#     - config.json contains no unsubstituted ${VAR} placeholders
#     - JS source files are served and contain fallback logic
#
# TDD: These tests are written BEFORE the implementation exists. They MUST
# fail on the current codebase and pass once the implementation is complete.
#
# Usage:
#   ./dev-testing/test_homepage_config_injection.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# Requirements:
#   - bash >= 4.0
#   - Docker (for container integration tests; auto-skipped if unavailable)
#   - curl  (for HTTP endpoint tests; auto-skipped if unavailable)
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

HOMEPAGE_DIR="${PROJECT_ROOT}/homepage"
DASHBOARD_JS="${HOMEPAGE_DIR}/js/dashboard.js"
STATUS_JS="${HOMEPAGE_DIR}/js/status.js"
CONFIG_TEMPLATE="${HOMEPAGE_DIR}/config.json.template"
DOCKERFILE="${HOMEPAGE_DIR}/Dockerfile"
COMPOSE_UNIFIED="${PROJECT_ROOT}/docker-compose-unified.yml"
COMPOSE_PI="${PROJECT_ROOT}/docker-compose-pi.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() {
    printf '  %s[PASS]%s %s\n' "${GREEN}" "${NC}" "$1"
    (( PASS_COUNT++ )) || true
}

fail() {
    printf '  %s[FAIL]%s %s\n' "${RED}" "${NC}" "$1"
    (( FAIL_COUNT++ )) || true
}

skip() {
    printf '  %s[SKIP]%s %s\n' "${YELLOW}" "${NC}" "$1"
    (( SKIP_COUNT++ )) || true
}

info() {
    printf '  %s[INFO]%s %s\n' "${BLUE}" "${NC}" "$1"
}

section() {
    printf '\n%s%s%s%s\n' "${BOLD}" "${CYAN}" "$1" "${NC}"
    printf '%s%s%s\n' "${CYAN}" "────────────────────────────────────────────────────────────" "${NC}"
}

# Returns 0 if pattern found in file, 1 if not
file_contains() {
    local pattern="$1"
    local file="$2"
    grep -qE "${pattern}" "${file}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf '\n%s%s' "${BOLD}" "${CYAN}"
printf '════════════════════════════════════════════════════════════\n'
printf '  Homepage Config Injection Tests\n'
printf '════════════════════════════════════════════════════════════\n'
printf '%s\n' "${NC}"

# =============================================================================
# Section 1: config.json.template — existence and placeholder coverage
# =============================================================================

section "config.json.template — existence"

if [[ -f "${CONFIG_TEMPLATE}" ]]; then
    pass "homepage/config.json.template exists"
else
    fail "homepage/config.json.template does not exist (must be created)"
fi

# ---------------------------------------------------------------------------
section "config.json.template — required port placeholders"
# ---------------------------------------------------------------------------

declare -a REQUIRED_PLACEHOLDERS=(
    'PLEX_PORT'
    'OVERSEERR_PORT'
    'RADARR_PORT'
    'SONARR_PORT'
    'PROWLARR_PORT'
    'QBITTORRENT_PORT'
    'TAUTULLI_PORT'
)

if [[ -f "${CONFIG_TEMPLATE}" ]]; then
    for placeholder in "${REQUIRED_PLACEHOLDERS[@]}"; do
        if file_contains "\\\$\{${placeholder}\}" "${CONFIG_TEMPLATE}"; then
            pass "config.json.template contains \${${placeholder}} placeholder"
        else
            fail "config.json.template is missing \${${placeholder}} placeholder"
        fi
    done

    # Template must contain JSON keys for each service
    if file_contains '"plex"' "${CONFIG_TEMPLATE}" && \
       file_contains '"radarr"' "${CONFIG_TEMPLATE}" && \
       file_contains '"sonarr"' "${CONFIG_TEMPLATE}"; then
        pass "config.json.template contains expected service JSON keys (plex, radarr, sonarr, …)"
    else
        fail "config.json.template is missing expected service-name JSON keys"
    fi
else
    for placeholder in "${REQUIRED_PLACEHOLDERS[@]}"; do
        fail "config.json.template missing — cannot verify \${${placeholder}} placeholder"
    done
    fail "config.json.template missing — cannot verify service JSON keys"
fi

# =============================================================================
# Section 2: Dockerfile — entrypoint for envsubst
# =============================================================================

section "homepage/Dockerfile — entrypoint script reference"

if [[ -f "${DOCKERFILE}" ]]; then
    pass "homepage/Dockerfile exists"
    if file_contains 'ENTRYPOINT|entrypoint|CMD.*\.sh|COPY.*\.sh' "${DOCKERFILE}"; then
        pass "homepage/Dockerfile references an entrypoint/CMD shell script"
    else
        fail "homepage/Dockerfile must reference an entrypoint shell script (for envsubst)"
    fi
else
    fail "homepage/Dockerfile does not exist"
fi

# ---------------------------------------------------------------------------
section "homepage entrypoint script — envsubst usage"
# ---------------------------------------------------------------------------

# Locate the entrypoint script referenced in the Dockerfile
ENTRYPOINT_SCRIPT=""
if [[ -f "${DOCKERFILE}" ]]; then
    ENTRYPOINT_SCRIPT_NAME=$(grep -oE 'COPY\s+([a-zA-Z0-9._/-]+\.sh)' "${DOCKERFILE}" 2>/dev/null \
        | awk '{print $2}' | head -1)
    if [[ -n "${ENTRYPOINT_SCRIPT_NAME}" ]]; then
        ENTRYPOINT_SCRIPT="${HOMEPAGE_DIR}/${ENTRYPOINT_SCRIPT_NAME}"
    else
        for candidate in \
            "${HOMEPAGE_DIR}/entrypoint.sh" \
            "${HOMEPAGE_DIR}/docker-entrypoint.sh" \
            "${HOMEPAGE_DIR}/start.sh"; do
            if [[ -f "${candidate}" ]]; then
                ENTRYPOINT_SCRIPT="${candidate}"
                break
            fi
        done
    fi
fi

if [[ -n "${ENTRYPOINT_SCRIPT}" ]] && [[ -f "${ENTRYPOINT_SCRIPT}" ]]; then
    ENTRYPOINT_REL="${ENTRYPOINT_SCRIPT#"${PROJECT_ROOT}/"}"
    pass "${ENTRYPOINT_REL} exists"

    if file_contains 'envsubst' "${ENTRYPOINT_SCRIPT}"; then
        pass "${ENTRYPOINT_REL} uses envsubst to substitute environment variables"
    else
        fail "${ENTRYPOINT_REL} must use envsubst to render config.json.template → config.json"
    fi

    if file_contains 'config\.json\.template' "${ENTRYPOINT_SCRIPT}"; then
        pass "${ENTRYPOINT_REL} references config.json.template (envsubst input)"
    else
        fail "${ENTRYPOINT_REL} must read config.json.template as the envsubst input"
    fi

    if file_contains 'config\.json' "${ENTRYPOINT_SCRIPT}"; then
        pass "${ENTRYPOINT_REL} references config.json (envsubst output)"
    else
        fail "${ENTRYPOINT_REL} must write the rendered template to config.json"
    fi

    if file_contains 'nginx|exec' "${ENTRYPOINT_SCRIPT}"; then
        pass "${ENTRYPOINT_REL} hands off to nginx after rendering config"
    else
        fail "${ENTRYPOINT_REL} must start nginx after rendering config.json (exec nginx or similar)"
    fi
else
    fail "No entrypoint shell script found in homepage/ — expected entrypoint.sh, docker-entrypoint.sh, or start.sh"
    info "Create an entrypoint script that runs: envsubst < config.json.template > /usr/share/nginx/html/config.json"
fi

# =============================================================================
# Section 3: dashboard.js — config.json fetch and fallback
# =============================================================================

section "homepage/js/dashboard.js — fetches /config.json"

if [[ -f "${DASHBOARD_JS}" ]]; then
    pass "homepage/js/dashboard.js exists"
else
    fail "homepage/js/dashboard.js does not exist"
fi

if [[ -f "${DASHBOARD_JS}" ]]; then
    if file_contains "fetch.*config\.json" "${DASHBOARD_JS}"; then
        pass "dashboard.js fetches /config.json"
    else
        fail "dashboard.js must fetch /config.json to read port configuration"
    fi

    if file_contains 'catch|\.catch\b' "${DASHBOARD_JS}"; then
        pass "dashboard.js has a catch block for /config.json fetch failures"
    else
        fail "dashboard.js must have a catch block providing fallback defaults when /config.json fails"
    fi

    if file_contains 'config\[|config\.' "${DASHBOARD_JS}"; then
        pass "dashboard.js reads port values from the fetched config object"
    else
        fail "dashboard.js must read port values from the fetched config object (e.g. config.plex)"
    fi
fi

# ---------------------------------------------------------------------------
section "homepage/js/dashboard.js — fallback defaults match canonical ports"
# ---------------------------------------------------------------------------

# Canonical port values that must appear in the fallback code
declare -A DEFAULT_PORTS_DASH=(
    [plex]=32400
    [overseerr]=5055
    [radarr]=7878
    [sonarr]=8989
    [prowlarr]=9696
    [qbittorrent]=8080
    [tautulli]=8181
)

if [[ -f "${DASHBOARD_JS}" ]]; then
    for service in "${!DEFAULT_PORTS_DASH[@]}"; do
        port="${DEFAULT_PORTS_DASH[${service}]}"
        if file_contains "${port}" "${DASHBOARD_JS}"; then
            pass "dashboard.js fallback contains port ${port} for ${service}"
        else
            fail "dashboard.js fallback is missing port ${port} for ${service} — must match current canonical value"
        fi
    done

    # Hardcoded port literals must NOT appear as a bare top-level 'const services' object
    # (i.e., they should only live inside the catch/fallback block)
    if file_contains 'const services\s*=\s*\{' "${DASHBOARD_JS}"; then
        # Old pattern still present — ensure it's inside a fallback
        if file_contains 'catch|fallback|defaults' "${DASHBOARD_JS}"; then
            pass "dashboard.js: legacy const-services pattern is guarded by a fallback block"
        else
            fail "dashboard.js has a bare top-level 'const services = {...}' with hardcoded ports — move to fallback"
        fi
    else
        pass "dashboard.js has no bare top-level hardcoded services object — ports come from config.json"
    fi
else
    for service in "${!DEFAULT_PORTS_DASH[@]}"; do
        fail "dashboard.js missing — cannot verify fallback port for ${service}"
    done
fi

# =============================================================================
# Section 4: status.js — config.json fetch and fallback
# =============================================================================

section "homepage/js/status.js — fetches /config.json"

if [[ -f "${STATUS_JS}" ]]; then
    pass "homepage/js/status.js exists"
else
    fail "homepage/js/status.js does not exist"
fi

if [[ -f "${STATUS_JS}" ]]; then
    if file_contains "fetch.*config\.json" "${STATUS_JS}"; then
        pass "status.js fetches /config.json"
    else
        fail "status.js must fetch /config.json to read health-check URL ports"
    fi

    if file_contains 'catch|\.catch\b' "${STATUS_JS}"; then
        pass "status.js has a catch block for /config.json fetch failures"
    else
        fail "status.js must have a catch block providing fallback defaults when /config.json fails"
    fi

    if file_contains 'checkAll|checkService' "${STATUS_JS}"; then
        pass "status.js still defines checkAll/checkService health-check functions (no regression)"
    else
        fail "status.js must still define checkAll/checkService — behavioral regression detected"
    fi

    if file_contains 'config\[|config\.' "${STATUS_JS}"; then
        pass "status.js reads port values from the fetched config object"
    else
        fail "status.js must read port values from the fetched config object (e.g. config.radarr)"
    fi
fi

# ---------------------------------------------------------------------------
section "homepage/js/status.js — fallback defaults match canonical ports"
# ---------------------------------------------------------------------------

declare -A DEFAULT_PORTS_STATUS=(
    [plex]=32400
    [overseerr]=5055
    [radarr]=7878
    [sonarr]=8989
    [prowlarr]=9696
    [qbittorrent]=8080
    [tautulli]=8181
)

if [[ -f "${STATUS_JS}" ]]; then
    for service in "${!DEFAULT_PORTS_STATUS[@]}"; do
        port="${DEFAULT_PORTS_STATUS[${service}]}"
        if file_contains "${port}" "${STATUS_JS}"; then
            pass "status.js fallback contains port ${port} for ${service}"
        else
            fail "status.js fallback is missing port ${port} for ${service} — must match current canonical value"
        fi
    done
else
    for service in "${!DEFAULT_PORTS_STATUS[@]}"; do
        fail "status.js missing — cannot verify fallback port for ${service}"
    done
fi

# =============================================================================
# Section 5: docker-compose-unified.yml — homepage service env vars
# =============================================================================

section "docker-compose-unified.yml — homepage service passes port env vars"

declare -a COMPOSE_PORT_VARS=(
    'PLEX_PORT'
    'RADARR_PORT'
    'SONARR_PORT'
    'OVERSEERR_PORT'
    'PROWLARR_PORT'
    'QBITTORRENT_PORT'
    'TAUTULLI_PORT'
)

if [[ -f "${COMPOSE_UNIFIED}" ]]; then
    for var in "${COMPOSE_PORT_VARS[@]}"; do
        if file_contains "${var}" "${COMPOSE_UNIFIED}"; then
            pass "docker-compose-unified.yml passes ${var} env var to homepage"
        else
            fail "docker-compose-unified.yml must pass ${var} env var to the homepage service"
        fi
    done
else
    fail "docker-compose-unified.yml not found at expected path"
fi

# =============================================================================
# Section 6: docker-compose-pi.yml — homepage service env vars
# =============================================================================

section "docker-compose-pi.yml — homepage service passes port env vars"

if [[ -f "${COMPOSE_PI}" ]]; then
    for var in "${COMPOSE_PORT_VARS[@]}"; do
        if file_contains "${var}" "${COMPOSE_PI}"; then
            pass "docker-compose-pi.yml passes ${var} env var to homepage"
        else
            fail "docker-compose-pi.yml must pass ${var} env var to the homepage service"
        fi
    done
else
    fail "docker-compose-pi.yml not found at expected path"
fi

# =============================================================================
# Section 7: Integration — container serves config.json with injected ports
# =============================================================================

section "Integration — Docker availability"

DOCKER_AVAILABLE=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_AVAILABLE=true
    pass "Docker is available — running container integration tests"
else
    skip "Docker is not available or daemon is not running — skipping container integration tests"
fi

CONTAINER_NAME=""
TEST_IMAGE=""

if [[ "${DOCKER_AVAILABLE}" == "true" ]]; then
    CONTAINER_NAME="simplarr-homepage-test-$$"
    TEST_IMAGE="simplarr-homepage-test-img-$$"
    CUSTOM_PLEX_PORT=43210
    CUSTOM_RADARR_PORT=47878
    CUSTOM_SONARR_PORT=48989
    CUSTOM_OVERSEERR_PORT=45055
    CUSTOM_PROWLARR_PORT=49696
    CUSTOM_QBITTORRENT_PORT=48080
    CUSTOM_TAUTULLI_PORT=48181
    HOST_PORT=18799

    # -------------------------------------------------------------------------
    section "Integration — build homepage image"
    # -------------------------------------------------------------------------

    BUILD_OUTPUT=$(docker build -t "${TEST_IMAGE}" "${HOMEPAGE_DIR}" 2>&1)
    BUILD_EXIT=$?

    # Cleanup after tests complete
    cleanup_container() {
        # shellcheck disable=SC2317  # reason: called by trap EXIT handler, not directly
        docker rm -f "${CONTAINER_NAME}" &>/dev/null || true
        # shellcheck disable=SC2317  # reason: called by trap EXIT handler, not directly
        docker rmi -f "${TEST_IMAGE}" &>/dev/null || true
    }
    trap cleanup_container EXIT

    if [[ "${BUILD_EXIT}" -eq 0 ]]; then
        pass "homepage Docker image builds successfully"
    else
        fail "homepage Docker image build failed — implementation may be incomplete"
        printf '%s  Build output (last 20 lines):%s\n' "${YELLOW}" "${NC}"
        echo "${BUILD_OUTPUT}" | tail -20 | sed 's/^/    /'
        DOCKER_AVAILABLE=false
    fi
fi

if [[ "${DOCKER_AVAILABLE}" == "true" ]]; then
    # -------------------------------------------------------------------------
    section "Integration — container starts and responds"
    # -------------------------------------------------------------------------

    docker run -d \
        --name "${CONTAINER_NAME}" \
        -p "${HOST_PORT}:80" \
        -e "PLEX_PORT=${CUSTOM_PLEX_PORT}" \
        -e "RADARR_PORT=${CUSTOM_RADARR_PORT}" \
        -e "SONARR_PORT=${CUSTOM_SONARR_PORT}" \
        -e "OVERSEERR_PORT=${CUSTOM_OVERSEERR_PORT}" \
        -e "PROWLARR_PORT=${CUSTOM_PROWLARR_PORT}" \
        -e "QBITTORRENT_PORT=${CUSTOM_QBITTORRENT_PORT}" \
        -e "TAUTULLI_PORT=${CUSTOM_TAUTULLI_PORT}" \
        "${TEST_IMAGE}" \
        &>/dev/null 2>&1

    READY=false
    WAIT_ATTEMPTS=0
    while [[ "${WAIT_ATTEMPTS}" -lt 10 ]]; do
        if curl -sf "http://localhost:${HOST_PORT}/" &>/dev/null; then
            READY=true
            break
        fi
        sleep 1
        (( WAIT_ATTEMPTS++ )) || true
    done

    if [[ "${READY}" == "true" ]]; then
        pass "Homepage container started and nginx is responding"
    else
        fail "Homepage container did not become ready within 10 seconds"
        info "Container logs:"
        docker logs "${CONTAINER_NAME}" 2>&1 | tail -20 | sed 's/^/    /'
        DOCKER_AVAILABLE=false
    fi
fi

if [[ "${DOCKER_AVAILABLE}" == "true" ]]; then
    # -------------------------------------------------------------------------
    section "Integration — /config.json endpoint"
    # -------------------------------------------------------------------------

    CONFIG_JSON=$(curl -sf "http://localhost:${HOST_PORT}/config.json" 2>/dev/null || echo "")

    if [[ -n "${CONFIG_JSON}" ]]; then
        pass "Container serves /config.json (HTTP 200, non-empty body)"
    else
        fail "Container did not serve /config.json — endpoint returned empty or error"
    fi

    if echo "${CONFIG_JSON}" | grep -q "${CUSTOM_PLEX_PORT}"; then
        pass "config.json contains injected PLEX_PORT=${CUSTOM_PLEX_PORT}"
    else
        fail "config.json does not contain injected PLEX_PORT=${CUSTOM_PLEX_PORT} (body: ${CONFIG_JSON})"
    fi

    if echo "${CONFIG_JSON}" | grep -q "${CUSTOM_RADARR_PORT}"; then
        pass "config.json contains injected RADARR_PORT=${CUSTOM_RADARR_PORT}"
    else
        fail "config.json does not contain injected RADARR_PORT=${CUSTOM_RADARR_PORT}"
    fi

    if echo "${CONFIG_JSON}" | grep -q "${CUSTOM_SONARR_PORT}"; then
        pass "config.json contains injected SONARR_PORT=${CUSTOM_SONARR_PORT}"
    else
        fail "config.json does not contain injected SONARR_PORT=${CUSTOM_SONARR_PORT}"
    fi

    if echo "${CONFIG_JSON}" | grep -q "${CUSTOM_OVERSEERR_PORT}"; then
        pass "config.json contains injected OVERSEERR_PORT=${CUSTOM_OVERSEERR_PORT}"
    else
        fail "config.json does not contain injected OVERSEERR_PORT=${CUSTOM_OVERSEERR_PORT}"
    fi

    if echo "${CONFIG_JSON}" | grep -q "${CUSTOM_PROWLARR_PORT}"; then
        pass "config.json contains injected PROWLARR_PORT=${CUSTOM_PROWLARR_PORT}"
    else
        fail "config.json does not contain injected PROWLARR_PORT=${CUSTOM_PROWLARR_PORT}"
    fi

    if echo "${CONFIG_JSON}" | grep -q "${CUSTOM_QBITTORRENT_PORT}"; then
        pass "config.json contains injected QBITTORRENT_PORT=${CUSTOM_QBITTORRENT_PORT}"
    else
        fail "config.json does not contain injected QBITTORRENT_PORT=${CUSTOM_QBITTORRENT_PORT}"
    fi

    if echo "${CONFIG_JSON}" | grep -q "${CUSTOM_TAUTULLI_PORT}"; then
        pass "config.json contains injected TAUTULLI_PORT=${CUSTOM_TAUTULLI_PORT}"
    else
        fail "config.json does not contain injected TAUTULLI_PORT=${CUSTOM_TAUTULLI_PORT}"
    fi

    # Default port 32400 should NOT appear — proves substitution ran
    if echo "${CONFIG_JSON}" | grep -q "32400"; then
        fail "config.json still contains default port 32400 — envsubst substitution may have failed"
    else
        pass "config.json does not contain default port 32400 (custom value correctly injected)"
    fi

    # -------------------------------------------------------------------------
    section "Integration — no unsubstituted placeholders in config.json"
    # -------------------------------------------------------------------------

    if echo "${CONFIG_JSON}" | grep -qE '\$\{[A-Z_]+\}'; then
        LEFTOVER=$(echo "${CONFIG_JSON}" | grep -oE '\$\{[A-Z_]+\}' | head -5 | tr '\n' ' ')
        fail "config.json still contains unsubstituted placeholders: ${LEFTOVER}"
    else
        pass "config.json has no unsubstituted \${VAR} placeholders — envsubst ran correctly"
    fi

    # config.json must be valid JSON
    if command -v python3 &>/dev/null; then
        if echo "${CONFIG_JSON}" | python3 -c "import sys, json; json.load(sys.stdin)" &>/dev/null; then
            pass "config.json is valid JSON"
        else
            fail "config.json is not valid JSON (malformed output from envsubst)"
        fi
    else
        skip "python3 not available — skipping JSON validity check"
    fi

    # -------------------------------------------------------------------------
    section "Integration — JS source files are served with fallback logic"
    # -------------------------------------------------------------------------

    DASHBOARD_SRC=$(curl -sf "http://localhost:${HOST_PORT}/js/dashboard.js" 2>/dev/null || echo "")
    if [[ -n "${DASHBOARD_SRC}" ]]; then
        pass "Container serves /js/dashboard.js"
        if echo "${DASHBOARD_SRC}" | grep -qE 'catch|fallback'; then
            pass "Served dashboard.js contains catch/fallback logic"
        else
            fail "Served dashboard.js does not contain catch/fallback logic — fallback will not activate"
        fi
    else
        fail "Container did not serve /js/dashboard.js"
    fi

    STATUS_SRC=$(curl -sf "http://localhost:${HOST_PORT}/js/status.js" 2>/dev/null || echo "")
    if [[ -n "${STATUS_SRC}" ]]; then
        pass "Container serves /js/status.js"
        if echo "${STATUS_SRC}" | grep -qE 'catch|fallback'; then
            pass "Served status.js contains catch/fallback logic"
        else
            fail "Served status.js does not contain catch/fallback logic — fallback will not activate"
        fi
    else
        fail "Container did not serve /js/status.js"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

printf '\n%s%s' "${BOLD}" "${CYAN}"
printf '════════════════════════════════════════════════════════════\n'
printf '  Summary\n'
printf '════════════════════════════════════════════════════════════\n'
printf '%s\n' "${NC}"

printf '  %sPassed:%s  %d\n' "${GREEN}" "${NC}" "${PASS_COUNT}"
printf '  %sFailed:%s  %d\n' "${RED}" "${NC}" "${FAIL_COUNT}"
printf '  %sSkipped:%s %d\n' "${YELLOW}" "${NC}" "${SKIP_COUNT}"
printf '\n'

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    printf '  %s%sAll tests passed. Config injection is correctly implemented.%s\n\n' "${GREEN}" "${BOLD}" "${NC}"
    exit 0
else
    printf '  %s%sTests failed. Implement config.json injection before merging.%s\n\n' "${RED}" "${BOLD}" "${NC}"
    printf '  Implementation checklist:\n'
    printf '    1. Create homepage/config.json.template with ${SERVICE_PORT} placeholders\n'
    printf '    2. Create homepage/entrypoint.sh that runs envsubst then exec nginx\n'
    printf '    3. Update homepage/Dockerfile to COPY and use the entrypoint script\n'
    printf '    4. Update homepage/js/dashboard.js to fetch /config.json with fallback\n'
    printf '    5. Update homepage/js/status.js to fetch /config.json with fallback\n'
    printf '    6. Add homepage environment port vars to docker-compose-unified.yml\n'
    printf '    7. Add homepage environment port vars to docker-compose-pi.yml\n'
    printf '\n'
    exit 1
fi
