#!/bin/bash
# =============================================================================
# configure.sh Idempotency Tests
# =============================================================================
# Verifies that every API-creating function in configure.sh performs a
# GET-before-POST existence check, and that running the script twice against
# a live stack produces no duplicate resources and exits cleanly.
#
# These tests are written BEFORE implementation (TDD red phase):
#   - Phase 2 fails because GET-before-POST logic does not yet exist
#   - Phase 3 fails because running twice creates duplicates / exits non-zero
#
# Usage:
#   ./dev-testing/test_configure_idempotent.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# Environment Variables (Phase 3):
#   SIMPLARR_TEST_TIMEOUT    — seconds to wait for container health (default: 120)
#   SIMPLARR_TEST_BASE_PORT  — override random base port for test services
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURE_SH="${PROJECT_ROOT}/configure.sh"

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

# Integration test state — set by Phase 3 setup, consumed by cleanup
_COMPOSE_PROJECT_NAME=""
_TEST_CONFIG_DIR=""
COMPOSE_AVAILABLE=false
declare -a COMPOSE_CMD=()

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317  # reason: called indirectly via EXIT trap
cleanup() {
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
    printf "%b%s%b\n" "${CYAN}" \
        "────────────────────────────────────────────────────────────" "${NC}"
}

# Extract a function body from configure.sh.
# Matches from "funcname()" to the first closing "}" at column 0.
extract_function() {
    local func_name=$1
    awk "/^${func_name}\(\)/,/^\}/" "${CONFIGURE_SH}"
}

# Return 0 if a bare GET curl call appears before the first POST curl call
# within the given function body text (passed on stdin via variable).
get_appears_before_post() {
    local func_body=$1
    local get_line post_line
    # GET = any curl call that does NOT use -X POST
    get_line=$(echo "${func_body}" | grep -n "curl" | grep -v "\-X POST" | head -1 | cut -d: -f1)
    post_line=$(echo "${func_body}" | grep -n "curl.*\-X POST" | head -1 | cut -d: -f1)
    if [[ -z "${get_line}" || -z "${post_line}" ]]; then
        return 1
    fi
    [[ "${get_line}" -lt "${post_line}" ]]
}

# Return 0 if the function body contains an "already configured" skip message.
has_already_configured_message() {
    local func_body=$1
    echo "${func_body}" | grep -qi "already configured"
}

# Return 0 if the function contains an early "return 0" (the skip path).
# The idempotency guard must return 0 so that set -e does not abort the
# caller on a re-run of a fully-configured stack.
has_skip_returns_zero() {
    local func_body=$1
    echo "${func_body}" | grep -q "return 0"
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  configure.sh Idempotency Tests\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

# =============================================================================
# Phase 1: ShellCheck
# =============================================================================

section "Phase 1: ShellCheck"

if ! command -v shellcheck &>/dev/null; then
    skip "shellcheck not installed — skipping Phase 1"
else
    if shellcheck --severity=style "${CONFIGURE_SH}"; then
        pass "configure.sh — zero ShellCheck warnings (idempotency code is style-clean)"
    else
        fail "configure.sh — ShellCheck reported warnings after idempotency changes"
    fi
fi

# =============================================================================
# Phase 2: GET-before-POST Static Code Analysis
# =============================================================================
# Each API-creating function must:
#   1. Issue a GET to the list endpoint BEFORE the POST
#   2. Skip with return 0 if the named resource already exists
#   3. Log an "(already configured, skipping)" message when skipping
#
# These tests FAIL before implementation because the functions currently
# jump straight to POST without any existence check.

section "Phase 2: GET-before-POST Static Code Analysis"

printf "\n"
info "Checking add_qbittorrent_to_radarr — GET /api/v3/downloadclient before POST"

FUNC_BODY=$(extract_function "add_qbittorrent_to_radarr")

if echo "${FUNC_BODY}" | grep -q "/api/v3/downloadclient"; then
    pass "add_qbittorrent_to_radarr — references /api/v3/downloadclient (GET list endpoint)"
else
    fail "add_qbittorrent_to_radarr — does not reference /api/v3/downloadclient for GET check"
fi

if get_appears_before_post "${FUNC_BODY}"; then
    pass "add_qbittorrent_to_radarr — GET list call appears before POST in function body"
else
    fail "add_qbittorrent_to_radarr — missing GET check before POST (not idempotent)"
fi

if has_already_configured_message "${FUNC_BODY}"; then
    pass "add_qbittorrent_to_radarr — logs '(already configured, skipping)' message"
else
    fail "add_qbittorrent_to_radarr — missing '(already configured)' skip log message"
fi

if has_skip_returns_zero "${FUNC_BODY}"; then
    pass "add_qbittorrent_to_radarr — skip path returns 0 (prevents set -e abort on re-run)"
else
    fail "add_qbittorrent_to_radarr — skip path must return 0, not 1"
fi

printf "\n"
info "Checking add_qbittorrent_to_sonarr — GET /api/v3/downloadclient before POST"

FUNC_BODY=$(extract_function "add_qbittorrent_to_sonarr")

if echo "${FUNC_BODY}" | grep -q "/api/v3/downloadclient"; then
    pass "add_qbittorrent_to_sonarr — references /api/v3/downloadclient (GET list endpoint)"
else
    fail "add_qbittorrent_to_sonarr — does not reference /api/v3/downloadclient for GET check"
fi

if get_appears_before_post "${FUNC_BODY}"; then
    pass "add_qbittorrent_to_sonarr — GET list call appears before POST in function body"
else
    fail "add_qbittorrent_to_sonarr — missing GET check before POST (not idempotent)"
fi

if has_already_configured_message "${FUNC_BODY}"; then
    pass "add_qbittorrent_to_sonarr — logs '(already configured, skipping)' message"
else
    fail "add_qbittorrent_to_sonarr — missing '(already configured)' skip log message"
fi

if has_skip_returns_zero "${FUNC_BODY}"; then
    pass "add_qbittorrent_to_sonarr — skip path returns 0 (prevents set -e abort on re-run)"
else
    fail "add_qbittorrent_to_sonarr — skip path must return 0, not 1"
fi

printf "\n"
info "Checking add_radarr_to_prowlarr — GET /api/v1/applications before POST"

FUNC_BODY=$(extract_function "add_radarr_to_prowlarr")

if echo "${FUNC_BODY}" | grep -q "/api/v1/applications"; then
    pass "add_radarr_to_prowlarr — references /api/v1/applications (GET list endpoint)"
else
    fail "add_radarr_to_prowlarr — does not reference /api/v1/applications for GET check"
fi

if get_appears_before_post "${FUNC_BODY}"; then
    pass "add_radarr_to_prowlarr — GET list call appears before POST in function body"
else
    fail "add_radarr_to_prowlarr — missing GET check before POST (not idempotent)"
fi

if has_already_configured_message "${FUNC_BODY}"; then
    pass "add_radarr_to_prowlarr — logs '(already configured, skipping)' message"
else
    fail "add_radarr_to_prowlarr — missing '(already configured)' skip log message"
fi

if has_skip_returns_zero "${FUNC_BODY}"; then
    pass "add_radarr_to_prowlarr — skip path returns 0 (prevents set -e abort on re-run)"
else
    fail "add_radarr_to_prowlarr — skip path must return 0, not 1"
fi

printf "\n"
info "Checking add_sonarr_to_prowlarr — GET /api/v1/applications before POST"

FUNC_BODY=$(extract_function "add_sonarr_to_prowlarr")

if echo "${FUNC_BODY}" | grep -q "/api/v1/applications"; then
    pass "add_sonarr_to_prowlarr — references /api/v1/applications (GET list endpoint)"
else
    fail "add_sonarr_to_prowlarr — does not reference /api/v1/applications for GET check"
fi

if get_appears_before_post "${FUNC_BODY}"; then
    pass "add_sonarr_to_prowlarr — GET list call appears before POST in function body"
else
    fail "add_sonarr_to_prowlarr — missing GET check before POST (not idempotent)"
fi

if has_already_configured_message "${FUNC_BODY}"; then
    pass "add_sonarr_to_prowlarr — logs '(already configured, skipping)' message"
else
    fail "add_sonarr_to_prowlarr — missing '(already configured)' skip log message"
fi

if has_skip_returns_zero "${FUNC_BODY}"; then
    pass "add_sonarr_to_prowlarr — skip path returns 0 (prevents set -e abort on re-run)"
else
    fail "add_sonarr_to_prowlarr — skip path must return 0, not 1"
fi

printf "\n"
info "Checking add_radarr_root_folder — GET /api/v3/rootfolder before POST"

FUNC_BODY=$(extract_function "add_radarr_root_folder")

if echo "${FUNC_BODY}" | grep -q "/api/v3/rootfolder"; then
    pass "add_radarr_root_folder — references /api/v3/rootfolder (GET list endpoint)"
else
    fail "add_radarr_root_folder — does not reference /api/v3/rootfolder for GET check"
fi

if get_appears_before_post "${FUNC_BODY}"; then
    pass "add_radarr_root_folder — GET list call appears before POST in function body"
else
    fail "add_radarr_root_folder — missing GET check before POST (not idempotent)"
fi

if has_already_configured_message "${FUNC_BODY}"; then
    pass "add_radarr_root_folder — logs '(already configured, skipping)' message"
else
    fail "add_radarr_root_folder — missing '(already configured)' skip log message"
fi

if has_skip_returns_zero "${FUNC_BODY}"; then
    pass "add_radarr_root_folder — skip path returns 0 (prevents set -e abort on re-run)"
else
    fail "add_radarr_root_folder — skip path must return 0, not 1"
fi

printf "\n"
info "Checking add_sonarr_root_folder — GET /api/v3/rootfolder before POST"

FUNC_BODY=$(extract_function "add_sonarr_root_folder")

if echo "${FUNC_BODY}" | grep -q "/api/v3/rootfolder"; then
    pass "add_sonarr_root_folder — references /api/v3/rootfolder (GET list endpoint)"
else
    fail "add_sonarr_root_folder — does not reference /api/v3/rootfolder for GET check"
fi

if get_appears_before_post "${FUNC_BODY}"; then
    pass "add_sonarr_root_folder — GET list call appears before POST in function body"
else
    fail "add_sonarr_root_folder — missing GET check before POST (not idempotent)"
fi

if has_already_configured_message "${FUNC_BODY}"; then
    pass "add_sonarr_root_folder — logs '(already configured, skipping)' message"
else
    fail "add_sonarr_root_folder — missing '(already configured)' skip log message"
fi

if has_skip_returns_zero "${FUNC_BODY}"; then
    pass "add_sonarr_root_folder — skip path returns 0 (prevents set -e abort on re-run)"
else
    fail "add_sonarr_root_folder — skip path must return 0, not 1"
fi

printf "\n"
info "Checking add_public_indexers — GET /api/v1/indexer before each POST"

FUNC_BODY=$(extract_function "add_public_indexers")

if echo "${FUNC_BODY}" | grep -q "/api/v1/indexer"; then
    pass "add_public_indexers — references /api/v1/indexer (GET list endpoint)"
else
    fail "add_public_indexers — does not reference /api/v1/indexer for GET check"
fi

if get_appears_before_post "${FUNC_BODY}"; then
    pass "add_public_indexers — GET list call appears before first POST in function body"
else
    fail "add_public_indexers — missing GET check before POST (not idempotent)"
fi

if has_already_configured_message "${FUNC_BODY}"; then
    pass "add_public_indexers — logs '(already configured, skipping)' for duplicate indexers"
else
    fail "add_public_indexers — missing '(already configured)' skip log for duplicate indexers"
fi

# =============================================================================
# Phase 3: Idempotency Integration Tests
# =============================================================================
# Spins up an isolated Radarr + Sonarr + Prowlarr stack, runs configure.sh
# twice, then verifies:
#   - The second run exits with code 0
#   - No duplicate resources exist in any service's API response
#   - The second run output contains "(already configured)" skip messages
#
# DESIGN NOTE — non-interactive execution:
#   QB_PASSWORD is set as an env var so get_qbittorrent_password() returns
#   immediately without calling docker logs.  OVERSEERR_URL is pointed at
#   the Radarr service: wait_for_service() passes (HTTP 401 is accepted), but
#   initialize_overseerr() finds no "initialized":true so the Overseerr block
#   is skipped.  stdin is redirected from /dev/null so any remaining read
#   prompts return an empty string immediately.

section "Phase 3: Idempotency Integration Tests"

if command -v docker &>/dev/null; then
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD=("docker" "compose")
        COMPOSE_AVAILABLE=true
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD=("docker-compose")
        COMPOSE_AVAILABLE=true
    fi
fi

if [[ "${COMPOSE_AVAILABLE}" != "true" ]]; then
    skip "Phase 3 — docker compose not available; skipping idempotency integration tests"
else
    _TIMEOUT="${SIMPLARR_TEST_TIMEOUT:-120}"
    _COMPOSE_PROJECT_NAME="simplarr-idem-$$"
    _TEST_CONFIG_DIR="$(mktemp -d -t "simplarr-idem-XXXXXX")"

    # Random base port in 21000–28999 to avoid collisions with the main test suite
    if [[ -n "${SIMPLARR_TEST_BASE_PORT:-}" ]]; then
        _BASE="${SIMPLARR_TEST_BASE_PORT}"
    else
        _BASE=$(( (RANDOM % 8000) + 21000 ))
    fi

    PORT_RADARR=$(( _BASE + 0 ))
    PORT_SONARR=$(( _BASE + 1 ))
    PORT_PROWLARR=$(( _BASE + 2 ))

    info "Project : ${_COMPOSE_PROJECT_NAME}"
    info "Config  : ${_TEST_CONFIG_DIR}"
    info "Ports   : radarr=${PORT_RADARR} sonarr=${PORT_SONARR} prowlarr=${PORT_PROWLARR}"

    # Create per-service config dirs and media dirs (needed so /movies and /tv
    # exist inside the containers; Radarr/Sonarr reject root folders whose
    # paths do not exist on the container filesystem).
    for _svc3 in radarr sonarr prowlarr; do
        mkdir -p "${_TEST_CONFIG_DIR}/${_svc3}"
    done
    mkdir -p "${_TEST_CONFIG_DIR}/movies" "${_TEST_CONFIG_DIR}/tv"

    # Write self-contained compose file with pinned images matching production.
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
      - ${_TEST_CONFIG_DIR}/movies:/movies
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
      - ${_TEST_CONFIG_DIR}/tv:/tv
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
COMPOSE_EOF

    pass "Generated self-contained test compose file"

    printf "\n"
    info "Starting test stack (radarr + sonarr + prowlarr)..."
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
        pass "Test stack reached healthy state"
        _STACK_HEALTHY=true
    else
        _COMPOSE_UP_EXIT=$?
        _STACK_HEALTHY=false
        if [[ "${_COMPOSE_UP_EXIT}" -eq 124 ]]; then
            fail "Test stack timed out after ${_TIMEOUT}s"
        else
            fail "Test stack failed to start (exit ${_COMPOSE_UP_EXIT})"
            info "Compose output: ${_COMPOSE_UP_OUTPUT}"
        fi
    fi

    if [[ "${_STACK_HEALTHY}" == "true" ]]; then
        # Wait up to 60 s for each *arr service to write its config.xml
        printf "\n"
        info "Waiting for *arr services to write config.xml..."
        _CONFIGS_READY=true

        for _svc3 in radarr sonarr prowlarr; do
            _cfg="${_TEST_CONFIG_DIR}/${_svc3}/config.xml"
            _wait_start="${SECONDS}"
            while [[ ! -f "${_cfg}" ]]; do
                _elapsed=$(( SECONDS - _wait_start ))
                if [[ "${_elapsed}" -ge 60 ]]; then
                    break
                fi
                sleep 2
            done
            if [[ -f "${_cfg}" ]]; then
                pass "${_svc3}/config.xml created"
            else
                fail "${_svc3}/config.xml not found after 60s"
                _CONFIGS_READY=false
            fi
        done

        if [[ "${_CONFIGS_READY}" == "true" ]]; then
            # Extract API keys using the same pattern as configure.sh
            _RADARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' \
                "${_TEST_CONFIG_DIR}/radarr/config.xml" 2>/dev/null || true)
            _SONARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' \
                "${_TEST_CONFIG_DIR}/sonarr/config.xml" 2>/dev/null || true)
            _PROWLARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' \
                "${_TEST_CONFIG_DIR}/prowlarr/config.xml" 2>/dev/null || true)

            if [[ -n "${_RADARR_KEY}" && -n "${_SONARR_KEY}" && -n "${_PROWLARR_KEY}" ]]; then
                pass "API keys extracted from config.xml files"
                _KEYS_READY=true
            else
                fail "Failed to extract API keys from one or more config.xml files"
                _KEYS_READY=false
            fi

            if [[ "${_KEYS_READY}" == "true" ]]; then
                # -----------------------------------------------------------------
                # First run — establish baseline configuration
                # -----------------------------------------------------------------
                printf "\n"
                info "Running configure.sh (run 1 — establish baseline)..."

                _FIRST_LOG="${_TEST_CONFIG_DIR}/run1.log"
                _FIRST_EXIT=0

                # OVERSEERR_URL points at Radarr so wait_for_service passes
                # (401 is accepted), but initialize_overseerr finds no
                # "initialized":true so Overseerr config is gracefully skipped.
                RADARR_URL="http://localhost:${PORT_RADARR}" \
                SONARR_URL="http://localhost:${PORT_SONARR}" \
                PROWLARR_URL="http://localhost:${PORT_PROWLARR}" \
                QBITTORRENT_URL="http://localhost:${PORT_RADARR}" \
                OVERSEERR_URL="http://localhost:${PORT_RADARR}" \
                QB_PASSWORD="test-password" \
                QB_USERNAME="admin" \
                QBITTORRENT_HOST="qbittorrent" \
                RADARR_HOST="radarr" \
                SONARR_HOST="sonarr" \
                PROWLARR_HOST="prowlarr" \
                MOVIES_PATH="/movies" \
                TV_PATH="/tv" \
                CONFIG_DIR="${_TEST_CONFIG_DIR}" \
                    bash "${CONFIGURE_SH}" </dev/null \
                    > "${_FIRST_LOG}" 2>&1 || _FIRST_EXIT=$?

                if [[ "${_FIRST_EXIT}" -eq 0 ]]; then
                    pass "Run 1 of configure.sh exited cleanly (exit 0)"
                else
                    info "Run 1 exited with code ${_FIRST_EXIT} (acceptable — " \
                         "qBittorrent is not in the test stack)"
                fi

                # -----------------------------------------------------------------
                # Second run — the idempotency check
                # Running configure.sh a second time on a fully-configured stack
                # must exit 0 and must NOT create duplicate resources.
                # Without the GET-before-POST fix:
                #   - add_qbittorrent_to_radarr/sonarr may create duplicate clients
                #   - add_radarr_root_folder rejects duplicate /movies → returns 1
                #     → set -e aborts the script → exit non-zero
                # -----------------------------------------------------------------
                printf "\n"
                info "Running configure.sh (run 2 — idempotency assertion)..."

                _SECOND_LOG="${_TEST_CONFIG_DIR}/run2.log"
                _SECOND_EXIT=0

                RADARR_URL="http://localhost:${PORT_RADARR}" \
                SONARR_URL="http://localhost:${PORT_SONARR}" \
                PROWLARR_URL="http://localhost:${PORT_PROWLARR}" \
                QBITTORRENT_URL="http://localhost:${PORT_RADARR}" \
                OVERSEERR_URL="http://localhost:${PORT_RADARR}" \
                QB_PASSWORD="test-password" \
                QB_USERNAME="admin" \
                QBITTORRENT_HOST="qbittorrent" \
                RADARR_HOST="radarr" \
                SONARR_HOST="sonarr" \
                PROWLARR_HOST="prowlarr" \
                MOVIES_PATH="/movies" \
                TV_PATH="/tv" \
                CONFIG_DIR="${_TEST_CONFIG_DIR}" \
                    bash "${CONFIGURE_SH}" </dev/null \
                    > "${_SECOND_LOG}" 2>&1 || _SECOND_EXIT=$?

                printf "\n"
                if [[ "${_SECOND_EXIT}" -eq 0 ]]; then
                    pass "Run 2 of configure.sh exited cleanly (exit 0) — script is idempotent"
                else
                    fail "Run 2 of configure.sh exited with code ${_SECOND_EXIT} — script is NOT idempotent"
                    if [[ -f "${_SECOND_LOG}" ]]; then
                        info "Last 20 lines of run 2 log:"
                        tail -20 "${_SECOND_LOG}" | while IFS= read -r _line; do
                            printf "    %s\n" "${_line}"
                        done
                    fi
                fi

                # Second run must output "(already configured)" skip messages
                if grep -qi "already configured" "${_SECOND_LOG}" 2>/dev/null; then
                    pass "Run 2 output contains '(already configured, skipping)' messages"
                else
                    fail "Run 2 output does not contain '(already configured)' messages"
                fi

                # -----------------------------------------------------------------
                # Verify API state: no duplicate resources after two runs
                # -----------------------------------------------------------------
                printf "\n"
                info "Querying APIs to verify no duplicate resources exist..."

                # Radarr download clients
                _RADARR_DL=$(curl -s \
                    -H "X-Api-Key: ${_RADARR_KEY}" \
                    "http://localhost:${PORT_RADARR}/api/v3/downloadclient" \
                    2>/dev/null || echo "[]")
                _RADARR_QB_COUNT=$(echo "${_RADARR_DL}" | \
                    grep -o '"name":"qBittorrent"' | wc -l | tr -d ' ')
                if [[ "${_RADARR_QB_COUNT}" -eq 1 ]]; then
                    pass "Radarr — exactly 1 qBittorrent download client (no duplicates)"
                elif [[ "${_RADARR_QB_COUNT}" -eq 0 ]]; then
                    fail "Radarr — 0 qBittorrent download clients (configure.sh did not add one)"
                else
                    fail "Radarr — ${_RADARR_QB_COUNT} qBittorrent download clients found (duplicates — not idempotent)"
                fi

                # Sonarr download clients
                _SONARR_DL=$(curl -s \
                    -H "X-Api-Key: ${_SONARR_KEY}" \
                    "http://localhost:${PORT_SONARR}/api/v3/downloadclient" \
                    2>/dev/null || echo "[]")
                _SONARR_QB_COUNT=$(echo "${_SONARR_DL}" | \
                    grep -o '"name":"qBittorrent"' | wc -l | tr -d ' ')
                if [[ "${_SONARR_QB_COUNT}" -eq 1 ]]; then
                    pass "Sonarr — exactly 1 qBittorrent download client (no duplicates)"
                elif [[ "${_SONARR_QB_COUNT}" -eq 0 ]]; then
                    fail "Sonarr — 0 qBittorrent download clients (configure.sh did not add one)"
                else
                    fail "Sonarr — ${_SONARR_QB_COUNT} qBittorrent download clients found (duplicates — not idempotent)"
                fi

                # Radarr root folders
                _RADARR_RF=$(curl -s \
                    -H "X-Api-Key: ${_RADARR_KEY}" \
                    "http://localhost:${PORT_RADARR}/api/v3/rootfolder" \
                    2>/dev/null || echo "[]")
                _RADARR_MOVIES_COUNT=$(echo "${_RADARR_RF}" | \
                    grep -o '"path":"/movies"' | wc -l | tr -d ' ')
                if [[ "${_RADARR_MOVIES_COUNT}" -eq 1 ]]; then
                    pass "Radarr — exactly 1 /movies root folder (no duplicates)"
                elif [[ "${_RADARR_MOVIES_COUNT}" -eq 0 ]]; then
                    fail "Radarr — 0 /movies root folders (configure.sh did not add one)"
                else
                    fail "Radarr — ${_RADARR_MOVIES_COUNT} /movies root folders found (duplicates — not idempotent)"
                fi

                # Sonarr root folders
                _SONARR_RF=$(curl -s \
                    -H "X-Api-Key: ${_SONARR_KEY}" \
                    "http://localhost:${PORT_SONARR}/api/v3/rootfolder" \
                    2>/dev/null || echo "[]")
                _SONARR_TV_COUNT=$(echo "${_SONARR_RF}" | \
                    grep -o '"path":"/tv"' | wc -l | tr -d ' ')
                if [[ "${_SONARR_TV_COUNT}" -eq 1 ]]; then
                    pass "Sonarr — exactly 1 /tv root folder (no duplicates)"
                elif [[ "${_SONARR_TV_COUNT}" -eq 0 ]]; then
                    fail "Sonarr — 0 /tv root folders (configure.sh did not add one)"
                else
                    fail "Sonarr — ${_SONARR_TV_COUNT} /tv root folders found (duplicates — not idempotent)"
                fi

                # Prowlarr applications
                _PROWLARR_APPS=$(curl -s \
                    -H "X-Api-Key: ${_PROWLARR_KEY}" \
                    "http://localhost:${PORT_PROWLARR}/api/v1/applications" \
                    2>/dev/null || echo "[]")
                _PROWLARR_RADARR_COUNT=$(echo "${_PROWLARR_APPS}" | \
                    grep -o '"name":"Radarr"' | wc -l | tr -d ' ')
                if [[ "${_PROWLARR_RADARR_COUNT}" -eq 1 ]]; then
                    pass "Prowlarr — exactly 1 Radarr application (no duplicates)"
                elif [[ "${_PROWLARR_RADARR_COUNT}" -eq 0 ]]; then
                    fail "Prowlarr — 0 Radarr applications (configure.sh did not add one)"
                else
                    fail "Prowlarr — ${_PROWLARR_RADARR_COUNT} Radarr applications found (duplicates — not idempotent)"
                fi

                _PROWLARR_SONARR_COUNT=$(echo "${_PROWLARR_APPS}" | \
                    grep -o '"name":"Sonarr"' | wc -l | tr -d ' ')
                if [[ "${_PROWLARR_SONARR_COUNT}" -eq 1 ]]; then
                    pass "Prowlarr — exactly 1 Sonarr application (no duplicates)"
                elif [[ "${_PROWLARR_SONARR_COUNT}" -eq 0 ]]; then
                    fail "Prowlarr — 0 Sonarr applications (configure.sh did not add one)"
                else
                    fail "Prowlarr — ${_PROWLARR_SONARR_COUNT} Sonarr applications found (duplicates — not idempotent)"
                fi

                # Prowlarr indexers — verify no duplicate names
                _PROWLARR_INDEXERS=$(curl -s \
                    -H "X-Api-Key: ${_PROWLARR_KEY}" \
                    "http://localhost:${PORT_PROWLARR}/api/v1/indexer" \
                    2>/dev/null || echo "[]")
                _TOTAL_IDX=$(echo "${_PROWLARR_INDEXERS}" | \
                    grep -o '"name":"[^"]*"' | wc -l | tr -d ' ')
                _UNIQUE_IDX=$(echo "${_PROWLARR_INDEXERS}" | \
                    grep -o '"name":"[^"]*"' | sort -u | wc -l | tr -d ' ')

                if [[ "${_TOTAL_IDX}" -eq 0 ]]; then
                    fail "Prowlarr — 0 indexers found (add_public_indexers did not add any)"
                elif [[ "${_TOTAL_IDX}" -eq "${_UNIQUE_IDX}" ]]; then
                    pass "Prowlarr — ${_TOTAL_IDX} indexer(s), all unique names (no duplicates)"
                else
                    _DUP=$(( _TOTAL_IDX - _UNIQUE_IDX ))
                    fail "Prowlarr — ${_DUP} duplicate indexer name(s) found after 2 runs (add_public_indexers not idempotent)"
                fi
            fi
        fi
    fi
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
    printf "  %b%d test(s) failed.%b\n\n" "${RED}${BOLD}" "${FAIL_COUNT}" "${NC}"
    exit 1
fi
