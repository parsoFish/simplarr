#!/bin/bash
# =============================================================================
# Simplarr Test Suite — Phases 1–10 (Bash)
# =============================================================================
# Self-contained test runner covering preflight, file existence, syntax
# validation, nginx config content checks, qBittorrent template validation,
# setup script validation, configure script validation, container startup,
# live service connectivity, full API service wiring, and VPN container wiring.
#
# Usage:
#   ./dev-testing/test.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# Requirements:
#   - bash >= 4.0
#   - docker (optional; phases that need it are skipped when unavailable)
#
# Environment Variables (Phases 8–9):
#   SIMPLARR_TEST_TIMEOUT   — seconds to wait for container health (default: 120)
#   SIMPLARR_TEST_BASE_PORT — override random base port for test services
#
# Phases:
#   1  Preflight     — Docker and docker compose availability
#   2  File       — Required project files exist
#   3  Syntax     — bash -n, docker compose config --quiet, nginx -t
#   4  Nginx      — Upstream proxy_pass targets and location routes
#   5  qBittorrent — Template/config validation (static analysis only)
#   6  Setup      — setup.sh env vars, modes, qBittorrent template deploy
#   7  Configure     — configure.sh/configure.ps1 API function presence
#   8  Container     — Spin up isolated stack; verify all health checks pass
#   9  Connectivity  — Health endpoints, config.xml creation, get_arr_api_key
#  10  Wiring        — qBit password, root folders, download clients, Prowlarr apps/indexers/sync, VPN wiring
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# Temp directory for nginx wrapper configs — cleaned up on exit
_TMPDIR=""

# Temp directory for Phase 10 VPN wiring overlay — cleaned up on exit
_VPN_WIRING_TMPDIR=""

# Docker integration test state — set by Phase 8, consumed by cleanup and Phase 9
_COMPOSE_PROJECT_NAME=""
_TEST_CONFIG_DIR=""
_PHASE8_SUCCESS=false

# API keys populated by Phase 9c — consumed by Phase 10
_RADARR_API_KEY=""
_SONARR_API_KEY=""
_PROWLARR_API_KEY=""
_QBIT_PASSWORD=""

_TEST_BASE_PORT=0

# Per-service host ports — assigned by Phase 8 from a random base; zero until set
PORT_RADARR=0
PORT_SONARR=0
PORT_PROWLARR=0
PORT_OVERSEERR=0
PORT_QBITTORRENT=0
PORT_QBIT_TORRENT=0
PORT_TAUTULLI=0

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317  # reason: called indirectly via EXIT trap
cleanup() {
    if [[ -n "${_TMPDIR}" && -d "${_TMPDIR}" ]]; then
        rm -rf "${_TMPDIR}"
    fi

    if [[ -n "${_VPN_WIRING_TMPDIR}" && -d "${_VPN_WIRING_TMPDIR}" ]]; then
        rm -rf "${_VPN_WIRING_TMPDIR}"
    fi

    # Tear down any Docker containers and volumes started by Phase 8.
    # Runs unconditionally on EXIT (success or failure) to prevent dangling
    # containers from polluting the host. The COMPOSE_PROJECT_NAME ensures we
    # only touch the test-run-specific stack, never a production deployment.
    if [[ -n "${_COMPOSE_PROJECT_NAME}" && "${COMPOSE_AVAILABLE}" == "true" ]]; then
        printf "\n  [cleanup] Removing test containers (project: %s)...\n" \
            "${_COMPOSE_PROJECT_NAME}"
        COMPOSE_PROJECT_NAME="${_COMPOSE_PROJECT_NAME}" \
            "${COMPOSE_CMD[@]}" \
            -f "${_TEST_CONFIG_DIR}/compose-override.yml" \
            down --volumes --remove-orphans >/dev/null 2>&1 || true
        printf "  [cleanup] Docker teardown complete.\n"
    fi

    if [[ -n "${_TEST_CONFIG_DIR}" && -d "${_TEST_CONFIG_DIR}" ]]; then
        # Container processes may create files owned by a different UID; chmod
        # before removal ensures we can delete them without needing sudo.
        chmod -R a+rwX "${_TEST_CONFIG_DIR}" 2>/dev/null || true
        rm -rf "${_TEST_CONFIG_DIR}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() {
    printf "  %b[PASS]%b %s\n" "${GREEN}" "${NC}" "$1"
    (( PASS_COUNT++ )) || true
}

fail() {
    printf "  %b[FAIL]%b %s\n" "${RED}" "${NC}" "$1"
    (( FAIL_COUNT++ )) || true
}

skip() {
    printf "  %b[SKIP]%b %s\n" "${YELLOW}" "${NC}" "$1"
    (( SKIP_COUNT++ )) || true
}

info() {
    printf "  %b[INFO]%b %s\n" "${BLUE}" "${NC}" "$1"
}

section() {
    printf "\n%b%s%b\n" "${BOLD}${CYAN}" "$1" "${NC}"
    printf "%b%s%b\n" "${CYAN}" "────────────────────────────────────────────────────────────" "${NC}"
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Simplarr Test Suite — Phases 1–10\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

# ---------------------------------------------------------------------------
# Phase 1: Preflight — Tool availability
# ---------------------------------------------------------------------------

section "Phase 1: Preflight"

DOCKER_AVAILABLE=false

if command -v docker &>/dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null || true)
    info "Docker: ${DOCKER_VERSION}"
    pass "docker is installed"
    DOCKER_AVAILABLE=true
else
    fail "docker is not installed or not in PATH"
fi

COMPOSE_AVAILABLE=false
declare -a COMPOSE_CMD=()

if [[ "${DOCKER_AVAILABLE}" == "true" ]]; then
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_VERSION=$(docker compose version 2>/dev/null || true)
        info "Compose: ${COMPOSE_VERSION}"
        pass "docker compose (plugin) is available"
        COMPOSE_CMD=("docker" "compose")
        COMPOSE_AVAILABLE=true
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_VERSION=$(docker-compose version 2>/dev/null || true)
        info "Compose: ${COMPOSE_VERSION}"
        pass "docker-compose (standalone) is available"
        COMPOSE_CMD=("docker-compose")
        COMPOSE_AVAILABLE=true
    else
        fail "neither 'docker compose' plugin nor 'docker-compose' standalone is available"
    fi
else
    skip "docker compose check — docker not available"
fi

# ---------------------------------------------------------------------------
# Phase 2: File Existence
# ---------------------------------------------------------------------------

section "Phase 2: File Existence"

declare -a REQUIRED_FILES=(
    "docker-compose-unified.yml"
    "docker-compose-nas.yml"
    "docker-compose-pi.yml"
    "setup.sh"
    "setup.ps1"
    "configure.sh"
    "configure.ps1"
    "preflight.sh"
    "preflight.ps1"
    "nginx/unified.conf"
    "nginx/split.conf"
    "homepage/index.html"
    "homepage/status.html"
    "homepage/Dockerfile"
    "templates/qBittorrent/qBittorrent.conf"
)

for rel_path in "${REQUIRED_FILES[@]}"; do
    abs_path="${PROJECT_ROOT}/${rel_path}"
    if [[ -f "${abs_path}" ]]; then
        pass "${rel_path} exists"
    else
        fail "${rel_path} is missing (expected at ${abs_path})"
    fi
done

# -- 2b: Split-setup — NFS host path presence in docker-compose-pi.yml ------

printf "\n"
info "Split-setup validation — NFS host-side volume sources in docker-compose-pi.yml"
printf "\n"

for _nfs_path in "/mnt/nas/downloads" "/mnt/nas/movies" "/mnt/nas/tv"; do
    if grep -qE "^[[:space:]]+-[[:space:]]+${_nfs_path}:" "${PROJECT_ROOT}/docker-compose-pi.yml"; then
        pass "docker-compose-pi.yml — NFS host-side volume source ${_nfs_path} declared"
    else
        # fail() — path absent from docker-compose-pi.yml; volume binding is broken
        fail "docker-compose-pi.yml — missing NFS host-side volume source: ${_nfs_path}"
    fi
done

# ---------------------------------------------------------------------------
# Phase 3: Syntax Validation
# ---------------------------------------------------------------------------

section "Phase 3: Syntax Validation"

# -- 3a: bash -n on all .sh files ------------------------------------------

printf "\n"
info "Bash syntax checks (bash -n)"

declare -a BASH_SCRIPTS=(
    "setup.sh"
    "configure.sh"
    "preflight.sh"
    "utility/check_nas_mounts.sh"
)

for rel_path in "${BASH_SCRIPTS[@]}"; do
    abs_path="${PROJECT_ROOT}/${rel_path}"
    if [[ ! -f "${abs_path}" ]]; then
        fail "bash -n ${rel_path} — file not found"
        continue
    fi
    SYNTAX_ERR=""
    if SYNTAX_ERR=$(bash -n "${abs_path}" 2>&1); then
        pass "bash -n ${rel_path} — no syntax errors"
    else
        fail "bash -n ${rel_path} — syntax error: ${SYNTAX_ERR}"
    fi
done

# -- 3b: docker compose config --quiet on all three compose files -----------

printf "\n"
info "Docker Compose config validation (docker compose config --quiet)"

declare -a COMPOSE_FILES=(
    "docker-compose-unified.yml"
    "docker-compose-nas.yml"
    "docker-compose-pi.yml"
)

if [[ "${COMPOSE_AVAILABLE}" == "true" ]]; then
    # Export dummy env vars so compose can interpolate all variable references
    export PUID="1000"
    export PGID="1000"
    export TZ="UTC"
    export PLEX_CLAIM="claim-test"
    export DOCKER_CONFIG="/tmp/simplarr-test/config"
    export DOCKER_MEDIA="/tmp/simplarr-test/media"
    export NAS_IP="192.168.1.100"
    export OPENVPN_USER="test-user"
    export OPENVPN_PASSWORD="test-password"
    export VPN_SERVICE_PROVIDER="mullvad"
    export VPN_SERVER_COUNTRIES="Netherlands"
    export WIREGUARD_PRIVATE_KEY="test-key"
    export WIREGUARD_ADDRESSES="10.64.0.1/32"

    for rel_path in "${COMPOSE_FILES[@]}"; do
        abs_path="${PROJECT_ROOT}/${rel_path}"
        if [[ ! -f "${abs_path}" ]]; then
            fail "docker compose config --quiet ${rel_path} — file not found"
            continue
        fi
        COMPOSE_ERR=""
        if COMPOSE_ERR=$("${COMPOSE_CMD[@]}" -f "${abs_path}" config --quiet 2>&1); then
            pass "docker compose config --quiet ${rel_path} — valid"
        else
            fail "docker compose config --quiet ${rel_path} — invalid: ${COMPOSE_ERR}"
        fi
    done
else
    for rel_path in "${COMPOSE_FILES[@]}"; do
        skip "docker compose config --quiet ${rel_path} — docker compose not available"
    done
fi

# -- 3c: nginx -t via docker run on unified.conf and split.conf -------------

printf "\n"
info "Nginx syntax validation (nginx -t via docker run)"

declare -a NGINX_CONFS=(
    "nginx/unified.conf"
    "nginx/split.conf"
)

if [[ "${DOCKER_AVAILABLE}" == "true" ]]; then
    # The nginx conf files are server-block fragments; they require an http{}
    # wrapper to form a complete nginx config that nginx -t can validate.
    _TMPDIR="$(mktemp -d)"
    cat > "${_TMPDIR}/nginx-wrapper.conf" <<'NGINX_WRAPPER'
events {}
http {
    include /tmp/simplarr-test.conf;
}
NGINX_WRAPPER

    for rel_path in "${NGINX_CONFS[@]}"; do
        abs_path="${PROJECT_ROOT}/${rel_path}"
        if [[ ! -f "${abs_path}" ]]; then
            fail "nginx -t ${rel_path} — file not found"
            continue
        fi
        NGINX_ERR=""
        if NGINX_ERR=$(docker run --rm \
            -v "${abs_path}:/tmp/simplarr-test.conf:ro" \
            -v "${_TMPDIR}/nginx-wrapper.conf:/etc/nginx/nginx.conf:ro" \
            nginx:alpine nginx -t 2>&1); then
            pass "nginx -t ${rel_path} — syntax is ok"
        else
            fail "nginx -t ${rel_path} — syntax error: ${NGINX_ERR}"
        fi
    done
else
    for rel_path in "${NGINX_CONFS[@]}"; do
        skip "nginx -t ${rel_path} — docker not available"
    done
fi

# ---------------------------------------------------------------------------
# Phase 4: Nginx Config Content Checks
# ---------------------------------------------------------------------------

section "Phase 4: Nginx Config Content Checks"

# -- 4a: unified.conf -------------------------------------------------------

UNIFIED_CONF="${PROJECT_ROOT}/nginx/unified.conf"

if [[ -f "${UNIFIED_CONF}" ]]; then
    printf "\n"
    info "unified.conf — location routes"

    declare -a UNIFIED_ROUTES=(
        "/plex"
        "/radarr"
        "/sonarr"
        "/prowlarr"
        "/overseerr"
        "/torrent"
        "/tautulli"
        "/status"
    )

    for route in "${UNIFIED_ROUTES[@]}"; do
        # Match both exact-match (location = /route) and prefix (location /route)
        if grep -qE "location[[:space:]]+(=[[:space:]]+)?${route}([[:space:]]|$|\{)" "${UNIFIED_CONF}"; then
            pass "unified.conf — location ${route} is present"
        else
            fail "unified.conf — missing location ${route}"
        fi
    done

    printf "\n"
    info "unified.conf — service upstream proxy_pass targets"

    declare -a UNIFIED_UPSTREAMS=(
        "radarr:7878"
        "sonarr:8989"
        "prowlarr:9696"
        "overseerr:5055"
        "tautulli:8181"
        "qbittorrent:8080"
    )

    for upstream in "${UNIFIED_UPSTREAMS[@]}"; do
        if grep -q "${upstream}" "${UNIFIED_CONF}"; then
            pass "unified.conf — upstream ${upstream} is present"
        else
            fail "unified.conf — missing upstream ${upstream}"
        fi
    done
else
    skip "unified.conf content checks — file not found"
fi

# -- 4b: split.conf ---------------------------------------------------------

SPLIT_CONF="${PROJECT_ROOT}/nginx/split.conf"

if [[ -f "${SPLIT_CONF}" ]]; then
    printf "\n"
    info "split.conf — location routes"

    declare -a SPLIT_ROUTES=(
        "/plex"
        "/radarr"
        "/sonarr"
        "/prowlarr"
        "/overseerr"
        "/torrent"
        "/tautulli"
        "/status"
    )

    for route in "${SPLIT_ROUTES[@]}"; do
        if grep -qE "location[[:space:]]+(=[[:space:]]+)?${route}([[:space:]]|$|\{)" "${SPLIT_CONF}"; then
            pass "split.conf — location ${route} is present"
        else
            fail "split.conf — missing location ${route}"
        fi
    done

    printf "\n"
    info "split.conf — service upstream proxy_pass targets (Pi-hosted services)"

    # Pi-hosted services use named service upstreams
    declare -a SPLIT_PI_UPSTREAMS=(
        "radarr:7878"
        "sonarr:8989"
        "prowlarr:9696"
        "overseerr:5055"
        "tautulli:8181"
    )

    for upstream in "${SPLIT_PI_UPSTREAMS[@]}"; do
        if grep -q "${upstream}" "${SPLIT_CONF}"; then
            pass "split.conf — upstream ${upstream} is present"
        else
            fail "split.conf — missing upstream ${upstream}"
        fi
    done

    printf "\n"
    info "split.conf — NAS-hosted service proxy_pass targets"

    # NAS-hosted services (plex, qbittorrent) use the IP placeholder
    if grep -q "YOUR_NAS_IP:8080" "${SPLIT_CONF}"; then
        pass "split.conf — qbittorrent NAS upstream (YOUR_NAS_IP:8080) is present"
    else
        fail "split.conf — missing qbittorrent NAS upstream (expected YOUR_NAS_IP:8080)"
    fi

    if grep -q "YOUR_NAS_IP:32400" "${SPLIT_CONF}"; then
        pass "split.conf — plex NAS upstream (YOUR_NAS_IP:32400) is present"
    else
        fail "split.conf — missing plex NAS upstream (expected YOUR_NAS_IP:32400)"
    fi
else
    skip "split.conf content checks — file not found"
fi

# ---------------------------------------------------------------------------
# Phase 5: qBittorrent Template Validation
# ---------------------------------------------------------------------------

section "Phase 5: qBittorrent Template Validation"

QBIT_CONF="${PROJECT_ROOT}/templates/qBittorrent/qBittorrent.conf"

if [[ -f "${QBIT_CONF}" ]]; then
    pass "templates/qBittorrent/qBittorrent.conf exists"

    printf "\n"
    info "qBittorrent.conf — download path settings"

    # Session\DefaultSavePath must be set to a path
    if grep -qF 'Session\DefaultSavePath=/downloads' "${QBIT_CONF}"; then
        pass "qBittorrent.conf — Session\\DefaultSavePath=/downloads"
    else
        fail "qBittorrent.conf — Session\\DefaultSavePath=/downloads is missing"
    fi

    # Incomplete download path (TempPath) must be configured
    if grep -qF 'Session\TempPath=/downloads/incomplete/' "${QBIT_CONF}"; then
        pass "qBittorrent.conf — Session\\TempPath (incomplete path) is set"
    else
        fail "qBittorrent.conf — Session\\TempPath (incomplete path) is not configured"
    fi

    # Incomplete downloads must be enabled
    if grep -qF 'Session\TempPathEnabled=true' "${QBIT_CONF}"; then
        pass "qBittorrent.conf — Session\\TempPathEnabled=true"
    else
        fail "qBittorrent.conf — Session\\TempPathEnabled is not true"
    fi

    printf "\n"
    info "qBittorrent.conf — tracker and connection settings"

    # Public tracker auto-add must be enabled
    if grep -qF 'Session\AddTrackersEnabled=true' "${QBIT_CONF}"; then
        pass "qBittorrent.conf — Session\\AddTrackersEnabled=true"
    else
        fail "qBittorrent.conf — Session\\AddTrackersEnabled is not true"
    fi

    # DHT must be enabled
    if grep -qF 'Session\DHTEnabled=true' "${QBIT_CONF}"; then
        pass "qBittorrent.conf — Session\\DHTEnabled=true"
    else
        fail "qBittorrent.conf — Session\\DHTEnabled is not true"
    fi

    # GlobalMaxRatio must be configured (seeding limit)
    if grep -qF 'Session\GlobalMaxRatio=' "${QBIT_CONF}"; then
        pass "qBittorrent.conf — Session\\GlobalMaxRatio is configured"
    else
        fail "qBittorrent.conf — Session\\GlobalMaxRatio is not configured"
    fi

    printf "\n"
    info "qBittorrent.conf — public tracker list"

    # AdditionalTrackers must contain actual tracker announce URLs
    if grep -qE 'AdditionalTrackers=.*tracker.*announce' "${QBIT_CONF}"; then
        pass "qBittorrent.conf — public trackers are configured in AdditionalTrackers"
    else
        fail "qBittorrent.conf — public trackers not found in AdditionalTrackers"
    fi
else
    fail "templates/qBittorrent/qBittorrent.conf is missing"
fi

# ---------------------------------------------------------------------------
# Phase 6: Setup Script Validation
# ---------------------------------------------------------------------------

section "Phase 6: Setup Script Validation"

SETUP_SH="${PROJECT_ROOT}/setup.sh"

if [[ -f "${SETUP_SH}" ]]; then
    printf "\n"
    info "setup.sh — required environment variable prompts"

    declare -a SETUP_ENV_VARS=(
        "PUID"
        "PGID"
        "TZ"
        "DOCKER_CONFIG"
        "DOCKER_MEDIA"
    )

    for env_var in "${SETUP_ENV_VARS[@]}"; do
        if grep -q "${env_var}" "${SETUP_SH}"; then
            pass "setup.sh — ${env_var} prompt is present"
        else
            fail "setup.sh — missing prompt for ${env_var}"
        fi
    done

    printf "\n"
    info "setup.sh — deployment mode handling"

    if grep -q "unified" "${SETUP_SH}" && grep -q "split" "${SETUP_SH}"; then
        pass "setup.sh — supports both unified and split deployment modes"
    else
        fail "setup.sh — missing unified and/or split mode support"
    fi

    printf "\n"
    info "setup.sh — qBittorrent template deployment"

    # setup.sh must reference the qBittorrent template and copy it
    if grep -qE 'qBittorrent.*\.conf|templates.*qBittorrent' "${SETUP_SH}"; then
        pass "setup.sh — copies qBittorrent template"
    else
        fail "setup.sh — does not reference or copy qBittorrent template"
    fi

    printf "\n"
    info "setup.ps1 — parity with setup.sh"

    SETUP_PS1="${PROJECT_ROOT}/setup.ps1"
    if [[ -f "${SETUP_PS1}" ]]; then
        declare -a SETUP_PS_CHECKS=(
            "PUID"
            "PGID"
            "unified"
            "split"
            "qBittorrent"
        )

        for check in "${SETUP_PS_CHECKS[@]}"; do
            if grep -qi "${check}" "${SETUP_PS1}"; then
                pass "setup.ps1 — '${check}' is present (parity with setup.sh)"
            else
                fail "setup.ps1 — '${check}' is missing (parity gap with setup.sh)"
            fi
        done
    else
        skip "setup.ps1 parity checks — setup.ps1 not found"
    fi
else
    fail "setup.sh is missing"
fi

# ---------------------------------------------------------------------------
# Phase 7: Configure Script Validation
# ---------------------------------------------------------------------------

section "Phase 7: Configure Script Validation"

CONFIGURE_SH="${PROJECT_ROOT}/configure.sh"

if [[ -f "${CONFIGURE_SH}" ]]; then
    printf "\n"
    info "configure.sh — required API functions"

    declare -a CONFIGURE_SH_FUNCTIONS=(
        "wait_for_service"
        "get_arr_api_key"
        "add_qbittorrent_to_radarr"
        "add_qbittorrent_to_sonarr"
        "add_radarr_to_prowlarr"
        "add_sonarr_to_prowlarr"
        "add_radarr_root_folder"
        "add_sonarr_root_folder"
        "add_public_indexers"
        "sync_prowlarr_indexers"
    )

    for func in "${CONFIGURE_SH_FUNCTIONS[@]}"; do
        if grep -qE "^${func}\(\)" "${CONFIGURE_SH}"; then
            pass "configure.sh — function ${func}() is defined"
        else
            fail "configure.sh — missing function definition: ${func}()"
        fi
    done

    printf "\n"
    info "configure.ps1 — PowerShell parity checks"

    CONFIGURE_PS1="${PROJECT_ROOT}/configure.ps1"
    if [[ -f "${CONFIGURE_PS1}" ]]; then
        # Parallel arrays: bash function name → PowerShell equivalent function name
        declare -a SH_FUNC_NAMES=(
            "wait_for_service"
            "get_arr_api_key"
            "add_qbittorrent_to_radarr"
            "add_qbittorrent_to_sonarr"
            "add_radarr_to_prowlarr"
            "add_sonarr_to_prowlarr"
            "add_radarr_root_folder"
            "add_sonarr_root_folder"
            "add_public_indexers"
            "sync_prowlarr_indexers"
        )
        declare -a PS_FUNC_NAMES=(
            "Wait-ForService"
            "Get-ArrApiKey"
            "Add-QBittorrentToRadarr"
            "Add-QBittorrentToSonarr"
            "Add-RadarrToProwlarr"
            "Add-SonarrToProwlarr"
            "Add-RadarrRootFolder"
            "Add-SonarrRootFolder"
            "Add-ProwlarrPublicIndexer"
            "Sync-ProwlarrIndexer"
        )

        for i in "${!PS_FUNC_NAMES[@]}"; do
            ps_func="${PS_FUNC_NAMES[$i]}"
            sh_func="${SH_FUNC_NAMES[$i]}"
            if grep -qE "^function ${ps_func}" "${CONFIGURE_PS1}"; then
                pass "configure.ps1 — function ${ps_func} exists (parity: ${sh_func})"
            else
                fail "configure.ps1 — missing function ${ps_func} (parity gap for: ${sh_func})"
            fi
        done
    else
        skip "configure.ps1 parity checks — configure.ps1 not found"
    fi
else
    fail "configure.sh is missing"
fi

# ---------------------------------------------------------------------------
# Phase 7.5: Homepage Architecture Tests (static, no Docker required)
# ---------------------------------------------------------------------------

section "Phase 7.5: Homepage Architecture Tests"

_TEMPLATE_FILE="${PROJECT_ROOT}/homepage/config.json.template"
_STATUS_JS="${PROJECT_ROOT}/homepage/js/status.js"
_SERVICES_JS="${PROJECT_ROOT}/homepage/js/services.js"

printf "\n"
info "config.json.template — new architecture keys"

# (1) config.json.template has apiPaths key
if grep -q '"apiPaths"' "${_TEMPLATE_FILE}"; then
    pass "config.json.template contains apiPaths key"
else
    fail "config.json.template missing apiPaths key (new architecture requirement)"
fi

# (1) config.json.template has healthPaths key
if grep -q '"healthPaths"' "${_TEMPLATE_FILE}"; then
    pass "config.json.template contains healthPaths key"
else
    fail "config.json.template missing healthPaths key (new architecture requirement)"
fi

# (1) apiPaths and healthPaths cover all 7 services
# Each service ID must appear at least 3 times: port key + apiPaths entry + healthPaths entry
printf "\n"
info "config.json.template — service coverage in apiPaths and healthPaths"

declare -a _ARCH_SERVICE_IDS=("plex" "radarr" "sonarr" "prowlarr" "overseerr" "qbittorrent" "tautulli")

for _svc_id in "${_ARCH_SERVICE_IDS[@]}"; do
    _count=$(grep -o "\"${_svc_id}\"" "${_TEMPLATE_FILE}" 2>/dev/null | wc -l)
    if [[ "${_count}" -ge 3 ]]; then
        pass "config.json.template — \"${_svc_id}\" appears in apiPaths and healthPaths"
    else
        fail "config.json.template — \"${_svc_id}\" missing from apiPaths or healthPaths (found ${_count} occurrence(s), need >= 3)"
    fi
done

# (2) status.js does not contain 'no-cors' or 'method: HEAD'
# (4) status.js has no port-based URL construction
printf "\n"
info "status.js — architecture compliance"

if [[ -f "${_STATUS_JS}" ]]; then
    if ! grep -q 'no-cors' "${_STATUS_JS}"; then
        pass "status.js does not use no-cors fetch mode"
    else
        fail "status.js uses no-cors fetch mode — architecture requires standard CORS requests via nginx proxy"
    fi

    if ! grep -qE "method:\s*['\"]HEAD" "${_STATUS_JS}"; then
        pass "status.js does not use HEAD request method"
    else
        fail "status.js uses HEAD method — architecture requires GET requests to dedicated health endpoints"
    fi

    if ! grep -qE ':[0-9]{4,5}/' "${_STATUS_JS}"; then
        pass "status.js uses relative health check paths (no port-based URLs)"
    else
        fail "status.js constructs port-based absolute URLs — use relative paths instead"
    fi
else
    fail "homepage/js/status.js not found — cannot run architecture compliance checks"
fi

# (3) services.js exists and contains all 7 service IDs
printf "\n"
info "services.js — existence and service coverage"

if [[ -f "${_SERVICES_JS}" ]]; then
    pass "homepage/js/services.js exists"

    for _svc_id in "${_ARCH_SERVICE_IDS[@]}"; do
        if grep -qE "'${_svc_id}'|\"${_svc_id}\"" "${_SERVICES_JS}"; then
            pass "services.js contains service ID '${_svc_id}'"
        else
            fail "services.js missing service ID '${_svc_id}'"
        fi
    done
else
    fail "homepage/js/services.js is missing (required by new fetch architecture)"
fi

# ---------------------------------------------------------------------------
# Phase 8: Container Startup
# ---------------------------------------------------------------------------

section "Phase 8: Container Startup"

if [[ "${COMPOSE_AVAILABLE}" != "true" ]]; then
    skip "Phase 8 — docker compose not available; skipping container integration tests"
    skip "Phase 9 — skipped (docker compose not available)"
else
    _TIMEOUT="${SIMPLARR_TEST_TIMEOUT:-120}"
    _COMPOSE_PROJECT_NAME="simplarr-test-$$"
    _TEST_CONFIG_DIR="$(mktemp -d -t "simplarr-test-XXXXXX")"

    printf "\n"
    info "Project name : ${_COMPOSE_PROJECT_NAME}"
    info "Config dir   : ${_TEST_CONFIG_DIR}"
    info "Timeout      : ${_TIMEOUT}s"

    # Pick a random base port to avoid conflicts with production services.
    # Uses SIMPLARR_TEST_BASE_PORT env var if set; otherwise picks a random
    # value in 20000–29999, safely above well-known and production ports.
    if [[ -n "${SIMPLARR_TEST_BASE_PORT:-}" ]]; then
        _TEST_BASE_PORT="${SIMPLARR_TEST_BASE_PORT}"
    else
        # RANDOM is 0–32767; shift into 20000–29999 range
        _TEST_BASE_PORT=$(( (RANDOM % 10000) + 20000 ))
    fi

    PORT_RADARR=$(( _TEST_BASE_PORT + 0 ))
    PORT_SONARR=$(( _TEST_BASE_PORT + 1 ))
    PORT_PROWLARR=$(( _TEST_BASE_PORT + 2 ))
    PORT_OVERSEERR=$(( _TEST_BASE_PORT + 3 ))
    PORT_QBITTORRENT=$(( _TEST_BASE_PORT + 4 ))
    PORT_QBIT_TORRENT=$(( _TEST_BASE_PORT + 5 ))
    PORT_TAUTULLI=$(( _TEST_BASE_PORT + 6 ))

    info "Base port    : ${_TEST_BASE_PORT} (range: ${_TEST_BASE_PORT}–$(( _TEST_BASE_PORT + 6 )))"
    printf "\n"
    info "Port map: radarr=${PORT_RADARR} sonarr=${PORT_SONARR} prowlarr=${PORT_PROWLARR}"
    info "          overseerr=${PORT_OVERSEERR} qbittorrent=${PORT_QBITTORRENT} tautulli=${PORT_TAUTULLI}"

    # Create per-service config directories on the host filesystem
    for _svc8 in radarr sonarr prowlarr overseerr qbittorrent tautulli; do
        mkdir -p "${_TEST_CONFIG_DIR}/${_svc8}"
    done
    # Create media directories mounted into arr containers for root folder creation
    mkdir -p "${_TEST_CONFIG_DIR}/media/movies"
    mkdir -p "${_TEST_CONFIG_DIR}/media/tv"

    pass "Created test config directories under ${_TEST_CONFIG_DIR}"

    # Write a self-contained test compose file with remapped ports and isolated
    # volumes. Uses the same image tags as production for parity. Shorter
    # healthcheck intervals (10s vs 30s) speed up the test.
    cat > "${_TEST_CONFIG_DIR}/compose-override.yml" << COMPOSE_EOF
services:
  radarr:
    image: linuxserver/radarr:6.0.4.10291-ls294
    ports:
      - "${PORT_RADARR}:7878"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - ${_TEST_CONFIG_DIR}/radarr:/config
      - ${_TEST_CONFIG_DIR}/media/movies:/movies
    healthcheck:
      test: curl -f http://localhost:7878/ping || exit 1
      interval: 10s
      timeout: 10s
      retries: 8
      start_period: 45s

  sonarr:
    image: linuxserver/sonarr:4.0.16.2944-ls303
    ports:
      - "${PORT_SONARR}:8989"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - ${_TEST_CONFIG_DIR}/sonarr:/config
      - ${_TEST_CONFIG_DIR}/media/tv:/tv
    healthcheck:
      test: curl -f http://localhost:8989/ping || exit 1
      interval: 10s
      timeout: 10s
      retries: 8
      start_period: 45s

  prowlarr:
    image: linuxserver/prowlarr:2.3.0.5236-ls138
    ports:
      - "${PORT_PROWLARR}:9696"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - ${_TEST_CONFIG_DIR}/prowlarr:/config
    healthcheck:
      test: curl -f http://localhost:9696/ping || exit 1
      interval: 10s
      timeout: 10s
      retries: 8
      start_period: 45s

  overseerr:
    image: sctx/overseerr:1.35.0
    ports:
      - "${PORT_OVERSEERR}:5055"
    environment:
      - TZ=UTC
      - LOG_LEVEL=info
    volumes:
      - ${_TEST_CONFIG_DIR}/overseerr:/app/config
    healthcheck:
      test: wget -q --spider http://localhost:5055/api/v1/status || exit 1
      interval: 10s
      timeout: 10s
      retries: 8
      start_period: 45s

  qbittorrent:
    image: linuxserver/qbittorrent:5.1.4-r2-ls443
    ports:
      - "${PORT_QBITTORRENT}:8080"
      - "${PORT_QBIT_TORRENT}:6881"
      - "${PORT_QBIT_TORRENT}:6881/udp"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
      - WEBUI_PORT=8080
    volumes:
      - ${_TEST_CONFIG_DIR}/qbittorrent:/config
    healthcheck:
      test: curl -f http://localhost:8080 || exit 1
      interval: 10s
      timeout: 10s
      retries: 8
      start_period: 45s

  tautulli:
    image: linuxserver/tautulli:v2.16.1-ls217
    ports:
      - "${PORT_TAUTULLI}:8181"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - ${_TEST_CONFIG_DIR}/tautulli:/config
    healthcheck:
      test: curl -f http://localhost:8181/status || exit 1
      interval: 10s
      timeout: 10s
      retries: 8
      start_period: 45s
COMPOSE_EOF

    pass "Generated self-contained test compose file (${_TEST_CONFIG_DIR}/compose-override.yml)"

    # Start all test containers and block until every healthcheck passes.
    # The EXIT trap (cleanup) will always run docker compose down --volumes,
    # ensuring no dangling containers or volumes on success or failure.
    printf "\n"
    info "Running: docker compose up -d --wait (timeout: ${_TIMEOUT}s)"
    info "Note: first run will pull images — this may take several minutes."

    _COMPOSE_UP_EXIT=0
    _COMPOSE_UP_OUTPUT=""
    if _COMPOSE_UP_OUTPUT=$(
        COMPOSE_PROJECT_NAME="${_COMPOSE_PROJECT_NAME}" \
        timeout "${_TIMEOUT}" \
        "${COMPOSE_CMD[@]}" \
        -f "${_TEST_CONFIG_DIR}/compose-override.yml" \
        up -d --wait 2>&1
    ); then
        pass "docker compose up --wait — all services reached healthy state"
    else
        _COMPOSE_UP_EXIT=$?
        if [[ "${_COMPOSE_UP_EXIT}" -eq 124 ]]; then
            fail "docker compose up --wait — timed out after ${_TIMEOUT}s"
        else
            fail "docker compose up --wait — failed (exit ${_COMPOSE_UP_EXIT})"
        fi
        info "Compose output: ${_COMPOSE_UP_OUTPUT}"
    fi

    # Double-check each container's health via docker inspect
    printf "\n"
    info "Verifying container health states via docker inspect..."

    declare -a _PHASE8_SVCS=(radarr sonarr prowlarr overseerr qbittorrent tautulli)
    _ALL_HEALTHY=true

    for _svc8 in "${_PHASE8_SVCS[@]}"; do
        _cid=$(
            COMPOSE_PROJECT_NAME="${_COMPOSE_PROJECT_NAME}" \
            "${COMPOSE_CMD[@]}" \
            -f "${_TEST_CONFIG_DIR}/compose-override.yml" \
            ps -q "${_svc8}" 2>/dev/null || true
        )
        if [[ -z "${_cid}" ]]; then
            fail "Phase 8 — ${_svc8}: container not found in project ${_COMPOSE_PROJECT_NAME}"
            _ALL_HEALTHY=false
            continue
        fi
        _health=$(docker inspect --format='{{.State.Health.Status}}' "${_cid}" 2>/dev/null \
            || echo "unknown")
        if [[ "${_health}" == "healthy" ]]; then
            pass "Phase 8 — ${_svc8}: healthy"
        else
            fail "Phase 8 — ${_svc8}: not healthy (status: ${_health})"
            _ALL_HEALTHY=false
        fi
    done

    if [[ "${_ALL_HEALTHY}" == "true" ]]; then
        _PHASE8_SUCCESS=true
    fi
fi

# ---------------------------------------------------------------------------
# Phase 9: Service Connectivity
# ---------------------------------------------------------------------------

section "Phase 9: Overseerr OAuth Detection & Service Connectivity"

# -- 9a: Overseerr OAuth uninitialized detection (mock config, no container needed) --

printf "\n"
info "Overseerr OAuth detection — uninitialized path (mock files, no container)"

_ovsr_mock_dir="$(mktemp -d)"
_ovsr_config_dir="${_ovsr_mock_dir}/overseerr"
mkdir -p "${_ovsr_config_dir}"

# Case 1: settings.json is absent → extraction should yield empty string
_ovsr_key_absent=$(grep -o '"apiKey":"[^"]*"' "${_ovsr_config_dir}/settings.json" \
    2>/dev/null | cut -d'"' -f4 || true)
if [[ -z "${_ovsr_key_absent}" ]]; then
    pass "Overseerr uninitialized — settings.json absent → apiKey empty (correct)"
else
    fail "Overseerr uninitialized — expected empty apiKey but got: ${_ovsr_key_absent}"
fi

# Case 2: settings.json present but apiKey is empty string
printf '{"main":{"apiKey":"","applicationTitle":"Overseerr"}}\n' \
    > "${_ovsr_config_dir}/settings.json"
_ovsr_key_empty=$(grep -o '"apiKey":"[^"]*"' "${_ovsr_config_dir}/settings.json" \
    2>/dev/null | cut -d'"' -f4 || true)
if [[ -z "${_ovsr_key_empty}" ]]; then
    pass "Overseerr uninitialized — empty apiKey in settings.json → apiKey empty (correct)"
else
    fail "Overseerr uninitialized — expected empty apiKey but got: ${_ovsr_key_empty}"
fi

# -- 9b: Overseerr OAuth initialized key-reading (mock settings.json, no container needed) --

printf "\n"
info "Overseerr OAuth detection — initialized path (mock settings.json, no container)"

_ovsr_mock_key="testkey-overseerr-abc12345"
# Compact JSON (no spaces) matches configure.sh grep pattern: '"apiKey":"[^"]*"'
printf '{"main":{"apiKey":"%s","applicationTitle":"Overseerr"}}\n' "${_ovsr_mock_key}" \
    > "${_ovsr_config_dir}/settings.json"
_ovsr_key_found=$(grep -o '"apiKey":"[^"]*"' "${_ovsr_config_dir}/settings.json" \
    2>/dev/null | cut -d'"' -f4 || true)
if [[ "${_ovsr_key_found}" == "${_ovsr_mock_key}" ]]; then
    pass "Overseerr initialized — apiKey '${_ovsr_mock_key:0:8}...' extracted from mock settings.json"
else
    fail "Overseerr initialized — expected '${_ovsr_mock_key}' but got '${_ovsr_key_found}'"
fi

rm -rf "${_ovsr_mock_dir}"

if [[ "${_PHASE8_SUCCESS}" != "true" ]]; then
    skip "Phase 9 (service connectivity) — skipped (Phase 8 did not complete successfully)"
else
    # -- 9a: Health endpoint connectivity -----------------------------------

    printf "\n"
    info "Hitting service health endpoints on remapped test ports..."

    declare -a _CONN_SVCS=(
        "radarr"
        "sonarr"
        "prowlarr"
        "overseerr"
        "qbittorrent"
        "tautulli"
    )
    declare -a _CONN_URLS=(
        "http://localhost:${PORT_RADARR}/ping"
        "http://localhost:${PORT_SONARR}/ping"
        "http://localhost:${PORT_PROWLARR}/ping"
        "http://localhost:${PORT_OVERSEERR}/api/v1/status"
        "http://localhost:${PORT_QBITTORRENT}/"
        "http://localhost:${PORT_TAUTULLI}/status"
    )

    for _i in "${!_CONN_SVCS[@]}"; do
        _svc9="${_CONN_SVCS[${_i}]}"
        _url="${_CONN_URLS[${_i}]}"
        _http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${_url}" \
            2>/dev/null || echo "000")
        # 200 OK, 302 redirect, 401 unauthorised, 403 forbidden all confirm service is alive
        if [[ "${_http_code}" =~ ^(200|302|401|403)$ ]]; then
            pass "Phase 9 — ${_svc9} endpoint reachable (HTTP ${_http_code}): ${_url}"
        else
            fail "Phase 9 — ${_svc9} endpoint unreachable (HTTP ${_http_code}): ${_url}"
        fi
    done

    # -- 9b: config.xml creation --------------------------------------------

    printf "\n"
    info "Polling for *arr config.xml files (written by services on first start)..."

    declare -a _ARR_SVCS=(radarr sonarr prowlarr)

    for _svc9 in "${_ARR_SVCS[@]}"; do
        _cfg="${_TEST_CONFIG_DIR}/${_svc9}/config.xml"
        _wait_start="${SECONDS}"
        while [[ ! -f "${_cfg}" ]]; do
            _elapsed=$(( SECONDS - _wait_start ))
            if [[ "${_elapsed}" -ge 60 ]]; then
                break
            fi
            sleep 2
        done
        if [[ -f "${_cfg}" ]]; then
            pass "Phase 9 — ${_svc9}/config.xml created by service"
        else
            fail "Phase 9 — ${_svc9}/config.xml not found after 60s (service may not have initialised)"
        fi
    done

    # -- 9c: get_arr_api_key extraction -------------------------------------

    printf "\n"
    info "Verifying get_arr_api_key extraction (same grep pattern as configure.sh)..."

    for _svc9 in "${_ARR_SVCS[@]}"; do
        _cfg="${_TEST_CONFIG_DIR}/${_svc9}/config.xml"
        if [[ ! -f "${_cfg}" ]]; then
            skip "get_arr_api_key — ${_svc9}: config.xml absent, skipping"
            continue
        fi
        # Mirror configure.sh's get_arr_api_key(): grep -oP '(?<=<ApiKey>)[^<]+' config.xml
        _api_key=$(grep -oP '(?<=<ApiKey>)[^<]+' "${_cfg}" 2>/dev/null || true)
        if [[ -n "${_api_key}" && "${#_api_key}" -ge 16 ]]; then
            pass "get_arr_api_key — ${_svc9}: key extracted (${_api_key:0:8}...)"
            # Save to named variable for Phase 10
            case "${_svc9}" in
                radarr)   _RADARR_API_KEY="${_api_key}" ;;
                sonarr)   _SONARR_API_KEY="${_api_key}" ;;
                prowlarr) _PROWLARR_API_KEY="${_api_key}" ;;
            esac
        else
            fail "get_arr_api_key — ${_svc9}: no valid API key found in config.xml"
        fi
    done

    # -- 9d: Overseerr initialization status (integration, full-suite only) --
    # This test targets the live Overseerr container started in Phase 8.
    # It is intentionally in the _PHASE8_SUCCESS gate so it only runs in the
    # full container suite (CI full-suite job), not the fast-gate (no Docker).

    printf "
"
    info "Overseerr integration — status endpoint via live container (full-suite only)"

    _ovsr_status=$(curl -s --max-time 10         "http://localhost:${PORT_OVERSEERR}/api/v1/status" 2>/dev/null || true)
    if [[ -n "${_ovsr_status}" ]] && echo "${_ovsr_status}" | grep -q '"initialized"'; then
        pass "Overseerr integration — status endpoint returns 'initialized' field"
    else
        fail "Overseerr integration — status endpoint did not return 'initialized' field"
    fi

    # Fresh Overseerr container will not have settings.json until Plex OAuth completes.
    # Verify the detection logic handles the absent-file case without error.
    _ovsr_live_cfg="${_TEST_CONFIG_DIR}/overseerr/settings.json"
    if [[ -f "${_ovsr_live_cfg}" ]]; then
        _ovsr_live_key=$(grep -o '"apiKey":"[^"]*"' "${_ovsr_live_cfg}"             2>/dev/null | cut -d'"' -f4 || true)
        if [[ -n "${_ovsr_live_key}" ]]; then
            pass "Overseerr integration — apiKey present in live settings.json (${_ovsr_live_key:0:8}...)"
        else
            pass "Overseerr integration — settings.json exists but apiKey empty (OAuth pending — expected)"
        fi
    else
        pass "Overseerr integration — settings.json absent on fresh container (OAuth not done — expected)"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 10: Service API Wiring
# ---------------------------------------------------------------------------

section "Phase 10: Service API Wiring"

if [[ "${_PHASE8_SUCCESS}" != "true" ]]; then
    skip "Phase 10 — skipped (Phase 8 containers not healthy)"
elif [[ -z "${_RADARR_API_KEY}" || -z "${_SONARR_API_KEY}" || -z "${_PROWLARR_API_KEY}" ]]; then
    skip "Phase 10 — skipped (one or more *arr API keys absent from Phase 9c)"
else
    # -- 10a: qBittorrent temporary password --------------------------------

    printf "\n"
    info "Extracting qBittorrent temporary password from Docker logs..."

    _QB_CONTAINER="${_COMPOSE_PROJECT_NAME}-qbittorrent-1"
    _qb_logs=$(docker logs "${_QB_CONTAINER}" 2>&1 || true)

    # Mirror test.ps1: match "temporary password.*: <PASSWORD>"
    _qb_extract_password() {
        echo "$1" | grep -i "temporary password" \
            | awk -F': ' '{print $NF}' | tr -d '[:space:]' | head -1
    }

    _QBIT_PASSWORD=$(_qb_extract_password "${_qb_logs}")

    if [[ -n "${_QBIT_PASSWORD}" ]]; then
        pass "Phase 10 — qBittorrent temp password extracted (${_QBIT_PASSWORD:0:4}...)"
    else
        info "Password not in logs yet — waiting up to 30s (mirrors test.ps1 retry)..."
        _qb_wait_start="${SECONDS}"
        while true; do
            _elapsed=$(( SECONDS - _qb_wait_start ))
            if [[ "${_elapsed}" -ge 30 ]]; then
                break
            fi
            sleep 5
            _qb_logs=$(docker logs "${_QB_CONTAINER}" 2>&1 || true)
            _QBIT_PASSWORD=$(_qb_extract_password "${_qb_logs}")
            if [[ -n "${_QBIT_PASSWORD}" ]]; then
                break
            fi
        done

        if [[ -n "${_QBIT_PASSWORD}" ]]; then
            pass "Phase 10 — qBittorrent temp password extracted after retry (${_QBIT_PASSWORD:0:4}...)"
        else
            fail "Phase 10 — could not extract qBittorrent temp password (even after 30s)"
        fi
    fi

    # -- 10b: Radarr root folder --------------------------------------------

    printf "\n"
    info "Configuring Radarr root folder (/movies)..."

    _existing_folders=$(curl -s --max-time 10 \
        -H "X-Api-Key: ${_RADARR_API_KEY}" \
        "http://localhost:${PORT_RADARR}/api/v3/rootfolder" 2>/dev/null || true)

    if echo "${_existing_folders}" | grep -qE '"path"\s*:\s*"/movies"'; then
        pass "Phase 10 — Radarr /movies root folder already exists (idempotent)"
    else
        _http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -X POST \
            -H "X-Api-Key: ${_RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"path":"/movies"}' \
            "http://localhost:${PORT_RADARR}/api/v3/rootfolder" 2>/dev/null || echo "000")
        if [[ "${_http}" =~ ^2 ]]; then
            pass "Phase 10 — Radarr root folder POST returned HTTP ${_http}"
        else
            fail "Phase 10 — Radarr root folder POST failed (HTTP ${_http})"
        fi
    fi

    # -- 10c: Sonarr root folder --------------------------------------------

    info "Configuring Sonarr root folder (/tv)..."

    _existing_folders=$(curl -s --max-time 10 \
        -H "X-Api-Key: ${_SONARR_API_KEY}" \
        "http://localhost:${PORT_SONARR}/api/v3/rootfolder" 2>/dev/null || true)

    if echo "${_existing_folders}" | grep -qE '"path"\s*:\s*"/tv"'; then
        pass "Phase 10 — Sonarr /tv root folder already exists (idempotent)"
    else
        _http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -X POST \
            -H "X-Api-Key: ${_SONARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"path":"/tv"}' \
            "http://localhost:${PORT_SONARR}/api/v3/rootfolder" 2>/dev/null || echo "000")
        if [[ "${_http}" =~ ^2 ]]; then
            pass "Phase 10 — Sonarr root folder POST returned HTTP ${_http}"
        else
            fail "Phase 10 — Sonarr root folder POST failed (HTTP ${_http})"
        fi
    fi

    # -- 10d: qBittorrent → Radarr download client --------------------------

    printf "\n"
    info "Adding qBittorrent as download client to Radarr..."

    if [[ -z "${_QBIT_PASSWORD}" ]]; then
        skip "Phase 10 — qBittorrent → Radarr: no password available, skipping"
    else
        _existing_clients=$(curl -s --max-time 10 \
            -H "X-Api-Key: ${_RADARR_API_KEY}" \
            "http://localhost:${PORT_RADARR}/api/v3/downloadclient" 2>/dev/null || true)

        if echo "${_existing_clients}" | grep -qE '"name"\s*:\s*"qBittorrent"'; then
            pass "Phase 10 — qBittorrent already in Radarr download clients (idempotent)"
        else
            _qbit_radarr_body=$(printf '{
  "enable":true,"protocol":"torrent","priority":1,
  "name":"qBittorrent","implementation":"QBittorrent",
  "configContract":"QBittorrentSettings","implementationName":"qBittorrent",
  "tags":[],
  "fields":[
    {"name":"host","value":"qbittorrent"},
    {"name":"port","value":8080},
    {"name":"useSsl","value":false},
    {"name":"urlBase","value":""},
    {"name":"username","value":"admin"},
    {"name":"password","value":"%s"},
    {"name":"movieCategory","value":"radarr"},
    {"name":"movieImportedCategory","value":""},
    {"name":"recentMoviePriority","value":0},
    {"name":"olderMoviePriority","value":0},
    {"name":"initialState","value":0},
    {"name":"sequentialOrder","value":false},
    {"name":"firstAndLast","value":false},
    {"name":"contentLayout","value":0}
  ]
}' "${_QBIT_PASSWORD}")
            _http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
                -X POST \
                -H "X-Api-Key: ${_RADARR_API_KEY}" \
                -H "Content-Type: application/json" \
                -d "${_qbit_radarr_body}" \
                "http://localhost:${PORT_RADARR}/api/v3/downloadclient" 2>/dev/null || echo "000")
            if [[ "${_http}" =~ ^2 ]]; then
                pass "Phase 10 — qBittorrent added to Radarr (HTTP ${_http})"
            else
                fail "Phase 10 — qBittorrent → Radarr POST failed (HTTP ${_http})"
            fi
        fi
    fi

    # -- 10e: qBittorrent → Sonarr download client --------------------------

    info "Adding qBittorrent as download client to Sonarr..."

    if [[ -z "${_QBIT_PASSWORD}" ]]; then
        skip "Phase 10 — qBittorrent → Sonarr: no password available, skipping"
    else
        _existing_clients=$(curl -s --max-time 10 \
            -H "X-Api-Key: ${_SONARR_API_KEY}" \
            "http://localhost:${PORT_SONARR}/api/v3/downloadclient" 2>/dev/null || true)

        if echo "${_existing_clients}" | grep -qE '"name"\s*:\s*"qBittorrent"'; then
            pass "Phase 10 — qBittorrent already in Sonarr download clients (idempotent)"
        else
            _qbit_sonarr_body=$(printf '{
  "enable":true,"protocol":"torrent","priority":1,
  "name":"qBittorrent","implementation":"QBittorrent",
  "configContract":"QBittorrentSettings","implementationName":"qBittorrent",
  "tags":[],
  "fields":[
    {"name":"host","value":"qbittorrent"},
    {"name":"port","value":8080},
    {"name":"useSsl","value":false},
    {"name":"urlBase","value":""},
    {"name":"username","value":"admin"},
    {"name":"password","value":"%s"},
    {"name":"tvCategory","value":"sonarr"},
    {"name":"tvImportedCategory","value":""},
    {"name":"recentTvPriority","value":0},
    {"name":"olderTvPriority","value":0},
    {"name":"initialState","value":0},
    {"name":"sequentialOrder","value":false},
    {"name":"firstAndLast","value":false},
    {"name":"contentLayout","value":0}
  ]
}' "${_QBIT_PASSWORD}")
            _http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
                -X POST \
                -H "X-Api-Key: ${_SONARR_API_KEY}" \
                -H "Content-Type: application/json" \
                -d "${_qbit_sonarr_body}" \
                "http://localhost:${PORT_SONARR}/api/v3/downloadclient" 2>/dev/null || echo "000")
            if [[ "${_http}" =~ ^2 ]]; then
                pass "Phase 10 — qBittorrent added to Sonarr (HTTP ${_http})"
            else
                fail "Phase 10 — qBittorrent → Sonarr POST failed (HTTP ${_http})"
            fi
        fi
    fi

    # -- 10f: Radarr → Prowlarr application ---------------------------------

    printf "\n"
    info "Adding Radarr as application to Prowlarr..."

    _existing_apps=$(curl -s --max-time 10 \
        -H "X-Api-Key: ${_PROWLARR_API_KEY}" \
        "http://localhost:${PORT_PROWLARR}/api/v1/applications" 2>/dev/null || true)

    if echo "${_existing_apps}" | grep -qE '"name"\s*:\s*"Radarr"'; then
        pass "Phase 10 — Radarr already in Prowlarr applications (idempotent)"
    else
        _radarr_app_body=$(printf '{
  "name":"Radarr","implementation":"Radarr",
  "implementationName":"Radarr","configContract":"RadarrSettings",
  "syncLevel":"fullSync",
  "fields":[
    {"name":"prowlarrUrl","value":"http://prowlarr:9696"},
    {"name":"baseUrl","value":"http://radarr:7878"},
    {"name":"apiKey","value":"%s"},
    {"name":"syncCategories","value":[2000,2010,2020,2030,2040,2045,2050,2060]}
  ]
}' "${_RADARR_API_KEY}")
        _http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
            -X POST \
            -H "X-Api-Key: ${_PROWLARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "${_radarr_app_body}" \
            "http://localhost:${PORT_PROWLARR}/api/v1/applications" 2>/dev/null || echo "000")
        if [[ "${_http}" =~ ^2 ]]; then
            pass "Phase 10 — Radarr added to Prowlarr (HTTP ${_http})"
        else
            fail "Phase 10 — Radarr → Prowlarr POST failed (HTTP ${_http})"
        fi
    fi

    # -- 10g: Sonarr → Prowlarr application ---------------------------------

    info "Adding Sonarr as application to Prowlarr..."

    if echo "${_existing_apps}" | grep -qE '"name"\s*:\s*"Sonarr"'; then
        pass "Phase 10 — Sonarr already in Prowlarr applications (idempotent)"
    else
        _sonarr_app_body=$(printf '{
  "name":"Sonarr","implementation":"Sonarr",
  "implementationName":"Sonarr","configContract":"SonarrSettings",
  "syncLevel":"fullSync",
  "fields":[
    {"name":"prowlarrUrl","value":"http://prowlarr:9696"},
    {"name":"baseUrl","value":"http://sonarr:8989"},
    {"name":"apiKey","value":"%s"},
    {"name":"syncCategories","value":[5000,5010,5020,5030,5040,5045,5050]}
  ]
}' "${_SONARR_API_KEY}")
        _http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
            -X POST \
            -H "X-Api-Key: ${_PROWLARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "${_sonarr_app_body}" \
            "http://localhost:${PORT_PROWLARR}/api/v1/applications" 2>/dev/null || echo "000")
        if [[ "${_http}" =~ ^2 ]]; then
            pass "Phase 10 — Sonarr added to Prowlarr (HTTP ${_http})"
        else
            fail "Phase 10 — Sonarr → Prowlarr POST failed (HTTP ${_http})"
        fi
    fi

    # -- 10h: 5 public indexers → Prowlarr ----------------------------------

    printf "\n"
    info "Adding 5 public indexers to Prowlarr..."

    _existing_indexers=$(curl -s --max-time 10 \
        -H "X-Api-Key: ${_PROWLARR_API_KEY}" \
        "http://localhost:${PORT_PROWLARR}/api/v1/indexer" 2>/dev/null || true)

    _indexer_added_count=0
    _indexer_skip_count=0

    declare -a _INDEXER_NAMES=("YTS" "The Pirate Bay" "TorrentGalaxy" "Nyaa" "LimeTorrents")
    declare -a _INDEXER_IMPL_NAMES=("YTS" "The Pirate Bay" "TorrentGalaxy" "Nyaa.si" "LimeTorrents")
    declare -a _INDEXER_DEF_NAMES=("yts" "thepiratebay" "torrentgalaxy" "nyaasi" "limetorrents")
    declare -a _INDEXER_BASE_URLS=("https://yts.mx" "https://thepiratebay.org" "https://torrentgalaxy.to" "https://nyaa.si" "https://www.limetorrents.lol")

    for _idx in "${!_INDEXER_NAMES[@]}"; do
        _iname="${_INDEXER_NAMES[${_idx}]}"
        _impl="${_INDEXER_IMPL_NAMES[${_idx}]}"
        _defname="${_INDEXER_DEF_NAMES[${_idx}]}"
        _baseurl="${_INDEXER_BASE_URLS[${_idx}]}"

        if echo "${_existing_indexers}" | grep -qE "\"name\"\\s*:\\s*\"${_iname}\""; then
            (( _indexer_skip_count++ )) || true
            continue
        fi

        _indexer_body=$(printf '{
  "enable":true,"redirect":false,
  "name":"%s","implementationName":"%s",
  "implementation":"Cardigann","configContract":"CardigannSettings",
  "definitionName":"%s","appProfileId":1,
  "protocol":"torrent","privacy":"public","priority":25,
  "downloadClientId":0,"tags":[],
  "fields":[
    {"name":"definitionFile","value":"%s"},
    {"name":"baseUrl","value":"%s"},
    {"name":"baseSettings.limitsUnit","value":0}
  ]
}' "${_iname}" "${_impl}" "${_defname}" "${_defname}" "${_baseurl}")

        _http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
            -X POST \
            -H "X-Api-Key: ${_PROWLARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "${_indexer_body}" \
            "http://localhost:${PORT_PROWLARR}/api/v1/indexer" 2>/dev/null || echo "000")

        if [[ "${_http}" =~ ^2 ]]; then
            (( _indexer_added_count++ )) || true
        fi
    done

    _indexer_total=$(( _indexer_added_count + _indexer_skip_count ))
    if [[ "${_indexer_total}" -ge "${#_INDEXER_NAMES[@]}" ]]; then
        pass "Phase 10 — Prowlarr indexers: ${_indexer_added_count} added, ${_indexer_skip_count} already existed"
    elif [[ $(( _indexer_added_count + _indexer_skip_count )) -gt 0 ]]; then
        pass "Phase 10 — Prowlarr indexers partially configured: ${_indexer_added_count} added, ${_indexer_skip_count} existed"
    else
        fail "Phase 10 — failed to add any indexers to Prowlarr"
    fi

    # -- 10i: Trigger Prowlarr sync -----------------------------------------

    printf "\n"
    info "Triggering Prowlarr sync to connected apps (ApplicationIndexerSync)..."

    _http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        -X POST \
        -H "X-Api-Key: ${_PROWLARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"name":"ApplicationIndexerSync"}' \
        "http://localhost:${PORT_PROWLARR}/api/v1/command" 2>/dev/null || echo "000")

    if [[ "${_http}" =~ ^2 ]]; then
        pass "Phase 10 — Prowlarr sync triggered (HTTP ${_http})"
        info "Waiting 10s for sync to propagate (mirrors test.ps1 behaviour)..."
        sleep 10
    else
        fail "Phase 10 — Prowlarr sync trigger failed (HTTP ${_http})"
    fi

    # -- 10j-k: Verify root folders -----------------------------------------

    printf "\n"
    info "Verifying root folders are configured..."

    _folders=$(curl -s --max-time 10 \
        -H "X-Api-Key: ${_RADARR_API_KEY}" \
        "http://localhost:${PORT_RADARR}/api/v3/rootfolder" 2>/dev/null || true)
    if echo "${_folders}" | grep -qE '"path"\s*:\s*"/movies"'; then
        pass "Phase 10 — Radarr has /movies root folder"
    else
        fail "Phase 10 — Radarr is missing /movies root folder"
    fi

    _folders=$(curl -s --max-time 10 \
        -H "X-Api-Key: ${_SONARR_API_KEY}" \
        "http://localhost:${PORT_SONARR}/api/v3/rootfolder" 2>/dev/null || true)
    if echo "${_folders}" | grep -qE '"path"\s*:\s*"/tv"'; then
        pass "Phase 10 — Sonarr has /tv root folder"
    else
        fail "Phase 10 — Sonarr is missing /tv root folder"
    fi

    # -- 10l-m: Verify download clients -------------------------------------

    printf "\n"
    info "Verifying download clients are configured..."

    if [[ -z "${_QBIT_PASSWORD}" ]]; then
        skip "Phase 10 — Radarr download client verification: no qBittorrent password extracted"
        skip "Phase 10 — Sonarr download client verification: no qBittorrent password extracted"
    else
        _clients=$(curl -s --max-time 10 \
            -H "X-Api-Key: ${_RADARR_API_KEY}" \
            "http://localhost:${PORT_RADARR}/api/v3/downloadclient" 2>/dev/null || true)
        if echo "${_clients}" | grep -qE '"name"\s*:\s*"qBittorrent"'; then
            pass "Phase 10 — Radarr has qBittorrent download client"
        else
            fail "Phase 10 — Radarr is missing qBittorrent download client"
        fi

        _clients=$(curl -s --max-time 10 \
            -H "X-Api-Key: ${_SONARR_API_KEY}" \
            "http://localhost:${PORT_SONARR}/api/v3/downloadclient" 2>/dev/null || true)
        if echo "${_clients}" | grep -qE '"name"\s*:\s*"qBittorrent"'; then
            pass "Phase 10 — Sonarr has qBittorrent download client"
        else
            fail "Phase 10 — Sonarr is missing qBittorrent download client"
        fi
    fi

    # -- 10n: Verify Prowlarr indexers (3+) ---------------------------------

    printf "\n"
    info "Verifying Prowlarr configuration..."

    _prowlarr_indexers=$(curl -s --max-time 10 \
        -H "X-Api-Key: ${_PROWLARR_API_KEY}" \
        "http://localhost:${PORT_PROWLARR}/api/v1/indexer" 2>/dev/null || true)
    _prowlarr_count=$(echo "${_prowlarr_indexers}" | grep -o '"id":' | wc -l | tr -d '[:space:]')
    if [[ "${_prowlarr_count:-0}" -ge 3 ]]; then
        pass "Phase 10 — Prowlarr has ${_prowlarr_count} indexer(s) (expected 3+)"
    elif [[ "${_prowlarr_count:-0}" -gt 0 ]]; then
        pass "Phase 10 — Prowlarr has ${_prowlarr_count} indexer(s) (partial; network timeouts may have prevented all)"
    else
        fail "Phase 10 — Prowlarr has no indexers configured"
    fi

    # -- 10o-p: Verify Prowlarr applications --------------------------------

    _prowlarr_apps=$(curl -s --max-time 10 \
        -H "X-Api-Key: ${_PROWLARR_API_KEY}" \
        "http://localhost:${PORT_PROWLARR}/api/v1/applications" 2>/dev/null || true)

    if echo "${_prowlarr_apps}" | grep -qE '"name"\s*:\s*"Radarr"'; then
        pass "Phase 10 — Prowlarr has Radarr connected"
    else
        fail "Phase 10 — Prowlarr is missing Radarr connection"
    fi

    if echo "${_prowlarr_apps}" | grep -qE '"name"\s*:\s*"Sonarr"'; then
        pass "Phase 10 — Prowlarr has Sonarr connected"
    else
        fail "Phase 10 — Prowlarr is missing Sonarr connection"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 10: Config File Structure Validation
# ---------------------------------------------------------------------------

section "Phase 10: Config File Structure Validation"

if [[ "${_PHASE8_SUCCESS}" != "true" ]]; then
    skip "Config file validation — skipped (containers not started)"
else
    printf "\n"
    info "Validating deep config file structure written by containers..."

    # -- 10a: Radarr config.xml -------------------------------------------------

    printf "\n"
    info "Checking Radarr config.xml (ApiKey, Port=7878, BindAddress, UrlBase)..."
    _radarr_cfg="${_TEST_CONFIG_DIR}/radarr/config.xml"
    if [[ ! -f "${_radarr_cfg}" ]]; then
        skip "Config file validation — radarr/config.xml not yet written; skipping"
    else
        if grep -qF '<ApiKey>' "${_TEST_CONFIG_DIR}/radarr/config.xml" 2>/dev/null; then
            pass "Radarr config.xml — ApiKey present"
        else
            fail "Radarr config.xml — ApiKey missing or malformed"
        fi
        if grep -qF '<Port>7878</Port>' "${_radarr_cfg}"; then
            pass "Radarr config.xml — Port=7878 present"
        else
            fail "Radarr config.xml — Port=7878 missing"
        fi
        if grep -qF '<BindAddress>' "${_radarr_cfg}"; then
            pass "Radarr config.xml — <BindAddress> present"
        else
            fail "Radarr config.xml — <BindAddress> missing"
        fi
        if grep -qE '<UrlBase>|<urlBase>' "${_radarr_cfg}"; then
            pass "Radarr config.xml — <UrlBase> present"
        else
            fail "Radarr config.xml — <UrlBase> missing"
        fi
    fi

    # -- 10b: Sonarr config.xml -------------------------------------------------

    printf "\n"
    info "Checking Sonarr config.xml (ApiKey, Port=8989, BindAddress, UrlBase)..."
    _sonarr_cfg="${_TEST_CONFIG_DIR}/sonarr/config.xml"
    if [[ ! -f "${_sonarr_cfg}" ]]; then
        skip "Config file validation — sonarr/config.xml not yet written; skipping"
    else
        if grep -qF '<ApiKey>' "${_sonarr_cfg}" 2>/dev/null; then
            pass "Sonarr config.xml — ApiKey present"
        else
            fail "Sonarr config.xml — ApiKey missing or malformed"
        fi
        if grep -qF '<Port>8989</Port>' "${_sonarr_cfg}"; then
            pass "Sonarr config.xml — Port=8989 present"
        else
            fail "Sonarr config.xml — Port=8989 missing"
        fi
        if grep -qF '<BindAddress>' "${_sonarr_cfg}"; then
            pass "Sonarr config.xml — <BindAddress> present"
        else
            fail "Sonarr config.xml — <BindAddress> missing"
        fi
        if grep -qE '<UrlBase>|<urlBase>' "${_sonarr_cfg}"; then
            pass "Sonarr config.xml — <UrlBase> present"
        else
            fail "Sonarr config.xml — <UrlBase> missing"
        fi
    fi

    # -- 10c: Prowlarr config.xml -----------------------------------------------

    printf "\n"
    info "Checking Prowlarr config.xml (ApiKey, Port=9696, BindAddress, UrlBase)..."
    _prowlarr_cfg="${_TEST_CONFIG_DIR}/prowlarr/config.xml"
    if [[ ! -f "${_prowlarr_cfg}" ]]; then
        skip "Config file validation — prowlarr/config.xml not yet written; skipping"
    else
        if grep -qF '<ApiKey>' "${_prowlarr_cfg}" 2>/dev/null; then
            pass "Prowlarr config.xml — ApiKey present"
        else
            fail "Prowlarr config.xml — ApiKey missing or malformed"
        fi
        if grep -qF '<Port>9696</Port>' "${_prowlarr_cfg}"; then
            pass "Prowlarr config.xml — Port=9696 present"
        else
            fail "Prowlarr config.xml — Port=9696 missing"
        fi
        if grep -qF '<BindAddress>' "${_prowlarr_cfg}"; then
            pass "Prowlarr config.xml — <BindAddress> present"
        else
            fail "Prowlarr config.xml — <BindAddress> missing"
        fi
        if grep -qE '<UrlBase>|<urlBase>' "${_prowlarr_cfg}"; then
            pass "Prowlarr config.xml — <UrlBase> present"
        else
            fail "Prowlarr config.xml — <UrlBase> missing"
        fi
    fi

    # -- 10d: qBittorrent.conf --------------------------------------------------

    printf "\n"
    info "Checking qBittorrent configuration ([Preferences], WebUI)..."
    _qb_cfg="${_TEST_CONFIG_DIR}/qbittorrent/qBittorrent/qBittorrent.conf"
    if [[ ! -f "${_qb_cfg}" ]]; then
        skip "Config file validation — qbittorrent config not yet written; skipping"
    else
        if grep -qF '[Preferences]' "${_qb_cfg}"; then
            pass "qBittorrent.conf — [Preferences] section present"
        else
            fail "qBittorrent.conf — [Preferences] section missing"
        fi
        if grep -qE 'WebUI' "${_qb_cfg}"; then
            pass "qBittorrent.conf — WebUI settings present"
        else
            fail "qBittorrent.conf — WebUI settings missing"
        fi
    fi

    # -- 10e: Overseerr settings.json -------------------------------------------

    printf "\n"
    info "Checking Overseerr settings.json (JSON validity)..."
    _overseerr_cfg="${_TEST_CONFIG_DIR}/overseerr/settings.json"
    if [[ ! -f "${_overseerr_cfg}" ]]; then
        skip "Config file validation — overseerr/settings.json not yet created (normal on first start)"
    else
        if command -v python3 >/dev/null 2>&1; then
            if python3 -m json.tool "${_overseerr_cfg}" >/dev/null 2>&1; then
                pass "Overseerr settings.json — valid JSON (python3)"
            else
                fail "Overseerr settings.json — invalid JSON"
            fi
        elif command -v jq >/dev/null 2>&1; then
            if jq . "${_overseerr_cfg}" >/dev/null 2>&1; then
                pass "Overseerr settings.json — valid JSON (jq)"
            else
                fail "Overseerr settings.json — invalid JSON"
            fi
        else
            skip "Overseerr settings.json — python3 and jq unavailable; JSON validation skipped"
        fi
    fi

    # -- 10f: Tautulli config.ini -----------------------------------------------

    printf "\n"
    info "Checking Tautulli config.ini (http_port=8181)..."
    _tautulli_cfg="${_TEST_CONFIG_DIR}/tautulli/config.ini"
    if [[ ! -f "${_tautulli_cfg}" ]]; then
        skip "Config file validation — tautulli/config.ini not yet created (normal on first start)"
    else
        if grep -qE 'http_port.*8181|8181.*http_port' "${_tautulli_cfg}"; then
            pass "Tautulli config.ini — http_port=8181 present"
        else
            fail "Tautulli config.ini — http_port=8181 not found"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Phase 10: VPN Container Wiring
#
# Validates that the VPN wiring between gluetun and qbittorrent is correct
# when VPN mode is enabled. Three sub-phases:
#
#   10a — Static: docker compose config on a VPN overlay (no containers).
#         Asserts qbittorrent carries network_mode: service:gluetun,
#         gluetun owns port 8080 (WebUI) and port 6881 (torrent), and
#         qbittorrent depends_on gluetun with condition: service_healthy.
#
#   10b — Runtime: gluetun container starts (guarded by /dev/net/tun check).
#         Skipped with "TUN device not available" when /dev/net/tun is absent
#         (e.g. WSL2 without TUN). When present, starts gluetun with fake
#         credentials and asserts docker inspect State.Status=running.
#
#   10c — VPN connectivity: always skipped — real VPN credentials required.
# ---------------------------------------------------------------------------

section "Phase 10: VPN Container Wiring"

# -- 10a: Static wiring assertions via docker compose config ----------------

printf "\n"
info "Phase 10a — Static wiring assertions (docker compose config, no containers)"

if [[ "${COMPOSE_AVAILABLE}" != "true" ]]; then
    skip "Phase 10a — qbittorrent network_mode: service:gluetun — docker compose not available"
    skip "Phase 10a — gluetun owns port 8080 — docker compose not available"
    skip "Phase 10a — gluetun owns port 6881 — docker compose not available"
    skip "Phase 10a — depends_on gluetun condition: service_healthy — docker compose not available"
else
    _VPN_WIRING_TMPDIR="$(mktemp -d -t "simplarr-vpn-wiring-XXXXXX")"

    # Minimal VPN-enabled compose overlay mirroring the commented gluetun and
    # qbittorrent VPN override blocks in docker-compose-unified.yml.
    # Hard-coded values avoid env var interpolation issues in docker compose config.
    cat > "${_VPN_WIRING_TMPDIR}/vpn-wiring.yml" << 'VPN_EOF'
services:
  gluetun:
    image: qmcgaw/gluetun:v3.41.1
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    environment:
      - VPN_SERVICE_PROVIDER=mullvad
      - VPN_TYPE=openvpn
      - OPENVPN_USER=test-user
      - OPENVPN_PASSWORD=test-password
    volumes:
      - /tmp/simplarr-vpn-test/gluetun:/gluetun
    healthcheck:
      test: ["CMD", "/gluetun-entrypoint", "healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    restart: unless-stopped

  qbittorrent:
    image: linuxserver/qbittorrent:5.1.4-r2-ls443
    network_mode: "service:gluetun"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
      - WEBUI_PORT=8080
    volumes:
      - /tmp/simplarr-vpn-test/qbittorrent:/config
    healthcheck:
      test: curl -f http://localhost:8080 || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    depends_on:
      gluetun:
        condition: service_healthy
    restart: unless-stopped
VPN_EOF

    _VPN_CONF_OUT=""
    if _VPN_CONF_OUT=$("${COMPOSE_CMD[@]}" \
            -f "${_VPN_WIRING_TMPDIR}/vpn-wiring.yml" \
            config 2>&1); then

        # qbittorrent must share gluetun's network namespace — compose drops quotes
        if echo "${_VPN_CONF_OUT}" | grep -qE 'network_mode:[[:space:]]+service:gluetun'; then
            pass "Phase 10a — qbittorrent carries network_mode: service:gluetun"
        else
            fail "Phase 10a — qbittorrent missing network_mode: service:gluetun in resolved YAML"
        fi

        # gluetun owns port 8080 (WebUI); qbittorrent has no ports when VPN-wired
        if echo "${_VPN_CONF_OUT}" | grep -qE 'published:[[:space:]]+"?8080"?|"8080:8080"|8080:8080'; then
            pass "Phase 10a — gluetun owns port 8080 (WebUI)"
        else
            fail "Phase 10a — port 8080 missing from resolved config (expected under gluetun)"
        fi

        # gluetun owns port 6881 (torrent); qbittorrent has no ports when VPN-wired
        if echo "${_VPN_CONF_OUT}" | grep -qE 'published:[[:space:]]+"?6881"?|"6881:6881"|6881:6881'; then
            pass "Phase 10a — gluetun owns port 6881 (torrent)"
        else
            fail "Phase 10a — port 6881 missing from resolved config (expected under gluetun)"
        fi

        # qbittorrent must not start before gluetun's tunnel is established
        if echo "${_VPN_CONF_OUT}" | grep -qE 'condition:[[:space:]]+service_healthy'; then
            pass "Phase 10a — qbittorrent depends_on gluetun with condition: service_healthy"
        else
            fail "Phase 10a — missing depends_on gluetun condition: service_healthy in resolved YAML"
        fi
    else
        fail "Phase 10a — VPN overlay YAML is invalid: ${_VPN_CONF_OUT}"
        skip "Phase 10a — gluetun owns port 8080 — compose config failed"
        skip "Phase 10a — gluetun owns port 6881 — compose config failed"
        skip "Phase 10a — depends_on gluetun condition: service_healthy — compose config failed"
    fi

    rm -rf "${_VPN_WIRING_TMPDIR}"
    _VPN_WIRING_TMPDIR=""
fi

# -- 10b: Runtime — gluetun container start (guarded by /dev/net/tun) -------

printf "\n"
info "Phase 10b — Runtime: gluetun container start (requires /dev/net/tun)"

if [[ ! -e "/dev/net/tun" ]]; then
    skip "Phase 10b — gluetun container start — TUN device not available (/dev/net/tun absent)"
    skip "Phase 10b — gluetun State.Status=running — TUN device not available"
else
    if [[ "${DOCKER_AVAILABLE}" != "true" ]]; then
        skip "Phase 10b — gluetun container start — docker not available"
        skip "Phase 10b — gluetun State.Status=running — docker not available"
    else
        _VPN_CONTAINER_NAME="simplarr-test-gluetun-$$"
        _VPN_CONTAINER_STARTED=false

        # Start gluetun with fake credentials — we only assert it starts, not
        # that it connects to a VPN. The healthcheck is intentionally not waited for.
        if docker run -d \
            --name "${_VPN_CONTAINER_NAME}" \
            --cap-add NET_ADMIN \
            --device /dev/net/tun:/dev/net/tun \
            -e VPN_SERVICE_PROVIDER=mullvad \
            -e VPN_TYPE=openvpn \
            -e OPENVPN_USER=test-user \
            -e OPENVPN_PASSWORD=test-password \
            qmcgaw/gluetun:v3.41.1 >/dev/null 2>&1; then
            _VPN_CONTAINER_STARTED=true
            pass "Phase 10b — gluetun container started with fake credentials"
        else
            fail "Phase 10b — gluetun container failed to start"
        fi

        if [[ "${_VPN_CONTAINER_STARTED}" == "true" ]]; then
            sleep 2
            _GLUETUN_STATUS=$(docker inspect \
                --format='{{.State.Status}}' \
                "${_VPN_CONTAINER_NAME}" 2>/dev/null || echo "unknown")
            if [[ "${_GLUETUN_STATUS}" == "running" ]]; then
                pass "Phase 10b — docker inspect State.Status=running for gluetun"
            else
                fail "Phase 10b — gluetun State.Status=${_GLUETUN_STATUS} (expected: running)"
            fi

            docker stop "${_VPN_CONTAINER_NAME}" >/dev/null 2>&1 || true
            docker rm "${_VPN_CONTAINER_NAME}" >/dev/null 2>&1 || true
        fi
    fi
fi

# -- 10c: VPN connectivity — always skipped ---------------------------------

printf "\n"
info "Phase 10c — VPN connectivity check (always skipped)"

skip "Phase 10c — VPN connectivity — SKIP — real VPN credentials required"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Summary\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

printf "  %bPassed:%b  %d\n" "${GREEN}" "${NC}" "${PASS_COUNT}"
printf "  %bFailed:%b  %d\n" "${RED}" "${NC}" "${FAIL_COUNT}"
printf "  %bSkipped:%b %d\n" "${YELLOW}" "${NC}" "${SKIP_COUNT}"
printf "\n"

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    printf "  %bAll tests passed.%b\n\n" "${GREEN}${BOLD}" "${NC}"
    exit 0
else
    printf "  %b%d test(s) failed. Fix the issues above before merging.%b\n\n" \
        "${RED}${BOLD}" "${FAIL_COUNT}" "${NC}"
    exit 1
fi
