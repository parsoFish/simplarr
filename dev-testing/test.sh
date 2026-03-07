#!/bin/bash
# =============================================================================
# Simplarr Test Suite — Phases 1–7 (Bash)
# =============================================================================
# Self-contained test runner covering preflight, file existence, syntax
# validation, nginx config content checks, qBittorrent template validation,
# setup script validation, and configure script validation. Mirrors
# dev-testing/test.ps1 phases 1–7.
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
# Phases:
#   1  Preflight  — Docker and docker compose availability
#   2  File       — Required project files exist
#   3  Syntax     — bash -n, docker compose config --quiet, nginx -t
#   4  Nginx      — Upstream proxy_pass targets and location routes
#   5  qBittorrent — Template/config validation (static analysis only)
#   6  Setup      — setup.sh env vars, modes, qBittorrent template deploy
#   7  Configure  — configure.sh/configure.ps1 API function presence
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

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317  # reason: called indirectly via EXIT trap
cleanup() {
    if [[ -n "${_TMPDIR}" && -d "${_TMPDIR}" ]]; then
        rm -rf "${_TMPDIR}"
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
printf "  Simplarr Test Suite — Phases 1–7\n"
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
