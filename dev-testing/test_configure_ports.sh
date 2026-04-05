#!/bin/bash
# =============================================================================
# configure.sh Port Parameterisation & Retry Configuration Tests
# =============================================================================
# Verifies that configure.sh:
#   1. Declares RADARR_PORT, SONARR_PORT, WAIT_MAX_ATTEMPTS, WAIT_RETRY_SECS
#      as environment-variable-overridable constants.
#   2. Replaces inline port literals (7878, 8989) in Overseerr API JSON bodies
#      with references to RADARR_PORT / SONARR_PORT.
#   3. Uses WAIT_MAX_ATTEMPTS and WAIT_RETRY_SECS in wait_for_service instead
#      of the previously hard-coded max_attempts=30 / sleep 2 literals.
#   4. Continues to pass bash -n syntax validation.
#   5. Continues to pass ShellCheck at severity=style.
#
# These are TDD tests — they MUST fail before the implementation is applied
# because the env vars do not yet exist and the port literals are still
# present in the source.
#
# Usage:
#   ./dev-testing/test_configure_ports.sh
#
# Exit Codes:
#   0 — all tests passed
#   1 — one or more tests failed
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

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

info() {
    printf '  %s[INFO]%s %s\n' "${BLUE}" "${NC}" "$1"
}

section() {
    printf '\n%s%s%s%s\n' "${BOLD}" "${CYAN}" "$1" "${NC}"
    printf '%s%s%s\n' "${CYAN}" \
        "────────────────────────────────────────────────────────────" "${NC}"
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf '\n%s%s' "${BOLD}" "${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  configure.sh Port Parameterisation & Retry Config Tests\n"
printf "════════════════════════════════════════════════════════════\n"
printf '%s\n' "${NC}"

# ---------------------------------------------------------------------------
# Guard: configure.sh must exist
# ---------------------------------------------------------------------------

section "Preconditions"

if [[ ! -f "${CONFIGURE_SH}" ]]; then
    fail "configure.sh not found at ${CONFIGURE_SH}"
    printf '\n%sAborting: configure.sh is required for these tests.%s\n\n' \
        "${RED}" "${NC}"
    exit 1
fi
pass "configure.sh exists"

# ---------------------------------------------------------------------------
# 1. Environment variable declarations
# ---------------------------------------------------------------------------
# configure.sh must declare each new env var using the ${VAR:-default} pattern
# so that callers can override them without editing the script.

section "Env Var Declarations"

# RADARR_PORT
if grep -qE 'RADARR_PORT=.*7878' "${CONFIGURE_SH}"; then
    pass "configure.sh declares RADARR_PORT with default 7878"
else
    fail "configure.sh does not declare RADARR_PORT with default 7878"
    info "Expected pattern: RADARR_PORT=\"\${RADARR_PORT:-7878}\""
fi

# SONARR_PORT
if grep -qE 'SONARR_PORT=.*8989' "${CONFIGURE_SH}"; then
    pass "configure.sh declares SONARR_PORT with default 8989"
else
    fail "configure.sh does not declare SONARR_PORT with default 8989"
    info "Expected pattern: SONARR_PORT=\"\${SONARR_PORT:-8989}\""
fi

# WAIT_MAX_ATTEMPTS
if grep -qE 'WAIT_MAX_ATTEMPTS=.*30' "${CONFIGURE_SH}"; then
    pass "configure.sh declares WAIT_MAX_ATTEMPTS with default 30"
else
    fail "configure.sh does not declare WAIT_MAX_ATTEMPTS with default 30"
    info "Expected pattern: WAIT_MAX_ATTEMPTS=\"\${WAIT_MAX_ATTEMPTS:-30}\""
fi

# WAIT_RETRY_SECS
if grep -qE 'WAIT_RETRY_SECS=.*2' "${CONFIGURE_SH}"; then
    pass "configure.sh declares WAIT_RETRY_SECS with default 2"
else
    fail "configure.sh does not declare WAIT_RETRY_SECS with default 2"
    info "Expected pattern: WAIT_RETRY_SECS=\"\${WAIT_RETRY_SECS:-2}\""
fi

# ---------------------------------------------------------------------------
# 2. Inline port literals removed from Overseerr JSON bodies
# ---------------------------------------------------------------------------
# The only acceptable usage of bare port numbers is inside default values
# for RADARR_URL / SONARR_URL (e.g. http://localhost:7878).  The JSON
# "port": <N> field passed to the Overseerr API must reference the env var.

section "No Inline Port Literals in Overseerr JSON Bodies"

# "port": 7878 — must not appear anywhere (it was in add_radarr_to_overseerr).
# The file stores escaped quotes as \" so use fixed-string matching (-F).
if grep -qF '\"port\": 7878' "${CONFIGURE_SH}"; then
    fail "configure.sh still contains literal \"port\": 7878 — replace with \${RADARR_PORT}"
else
    pass "configure.sh has no literal \"port\": 7878 in JSON bodies"
fi

# "port": 8989 — must not appear anywhere (it was in add_sonarr_to_overseerr)
if grep -qF '\"port\": 8989' "${CONFIGURE_SH}"; then
    fail "configure.sh still contains literal \"port\": 8989 — replace with \${SONARR_PORT}"
else
    pass "configure.sh has no literal \"port\": 8989 in JSON bodies"
fi

# ---------------------------------------------------------------------------
# 3. JSON bodies reference the env vars
# ---------------------------------------------------------------------------

section "Overseerr JSON Bodies Use Env Var References"

# add_radarr_to_overseerr must reference RADARR_PORT
if grep -q 'RADARR_PORT' "${CONFIGURE_SH}"; then
    pass "configure.sh references RADARR_PORT (used in Overseerr Radarr JSON body)"
else
    fail "configure.sh does not reference RADARR_PORT"
    info "Expected: \"port\": \${RADARR_PORT} inside add_radarr_to_overseerr"
fi

# add_sonarr_to_overseerr must reference SONARR_PORT
if grep -q 'SONARR_PORT' "${CONFIGURE_SH}"; then
    pass "configure.sh references SONARR_PORT (used in Overseerr Sonarr JSON body)"
else
    fail "configure.sh does not reference SONARR_PORT"
    info "Expected: \"port\": \${SONARR_PORT} inside add_sonarr_to_overseerr"
fi

# Verify the env var appears specifically inside the function body, not only
# as the initial declaration at the top.  We use awk to isolate the function.
radarr_fn_body=$(awk '/^add_radarr_to_overseerr\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
    "${CONFIGURE_SH}")
if echo "${radarr_fn_body}" | grep -q 'RADARR_PORT'; then
    pass "add_radarr_to_overseerr() body references RADARR_PORT"
else
    fail "add_radarr_to_overseerr() body does not reference RADARR_PORT"
fi

sonarr_fn_body=$(awk '/^add_sonarr_to_overseerr\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
    "${CONFIGURE_SH}")
if echo "${sonarr_fn_body}" | grep -q 'SONARR_PORT'; then
    pass "add_sonarr_to_overseerr() body references SONARR_PORT"
else
    fail "add_sonarr_to_overseerr() body does not reference SONARR_PORT"
fi

# ---------------------------------------------------------------------------
# 4. wait_for_service uses env vars, not hard-coded literals
# ---------------------------------------------------------------------------

section "wait_for_service Retry Configuration"

wait_fn_body=$(awk '/^wait_for_service\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
    "${CONFIGURE_SH}")

# Must reference WAIT_MAX_ATTEMPTS
if echo "${wait_fn_body}" | grep -q 'WAIT_MAX_ATTEMPTS'; then
    pass "wait_for_service() references WAIT_MAX_ATTEMPTS"
else
    fail "wait_for_service() does not reference WAIT_MAX_ATTEMPTS"
    info "Expected: local max_attempts=\${WAIT_MAX_ATTEMPTS:-30}"
fi

# Must reference WAIT_RETRY_SECS
if echo "${wait_fn_body}" | grep -q 'WAIT_RETRY_SECS'; then
    pass "wait_for_service() references WAIT_RETRY_SECS"
else
    fail "wait_for_service() does not reference WAIT_RETRY_SECS"
    info "Expected: sleep \"\${WAIT_RETRY_SECS:-2}\""
fi

# Must NOT hard-code max_attempts=30 as a bare literal
# (pattern: assignment of 30 without a ${ variable reference)
if echo "${wait_fn_body}" | grep -qE 'max_attempts=30[^}]?$'; then
    fail "wait_for_service() still hard-codes max_attempts=30 — use WAIT_MAX_ATTEMPTS"
else
    pass "wait_for_service() does not hard-code max_attempts=30"
fi

# Must NOT hard-code sleep 2 as a bare literal at end of line
if echo "${wait_fn_body}" | grep -qE 'sleep 2$'; then
    fail "wait_for_service() still hard-codes 'sleep 2' — use WAIT_RETRY_SECS"
else
    pass "wait_for_service() does not hard-code 'sleep 2'"
fi

# ---------------------------------------------------------------------------
# 5. Syntax validation
# ---------------------------------------------------------------------------

section "Bash Syntax Validation"

if bash -n "${CONFIGURE_SH}" 2>&1; then
    pass "configure.sh passes bash -n syntax check"
else
    fail "configure.sh fails bash -n syntax check"
fi

# ---------------------------------------------------------------------------
# 6. ShellCheck (if available)
# ---------------------------------------------------------------------------

section "ShellCheck Static Analysis"

if ! command -v shellcheck &>/dev/null; then
    printf '  %s[SKIP]%s shellcheck not installed — skipping\n' "${YELLOW}" "${NC}"
else
    if shellcheck --severity=style "${CONFIGURE_SH}"; then
        pass "configure.sh — zero ShellCheck warnings after port parameterisation"
    else
        fail "configure.sh — ShellCheck reported warnings (see output above)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%s%s' "${BOLD}" "${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Summary\n"
printf "════════════════════════════════════════════════════════════\n"
printf '%s\n' "${NC}"

printf '  %sPassed:%s %d\n' "${GREEN}" "${NC}" "${PASS_COUNT}"
printf '  %sFailed:%s %d\n' "${RED}" "${NC}" "${FAIL_COUNT}"
printf "\n"

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    printf '  %s%sAll tests passed.%s\n\n' "${GREEN}" "${BOLD}" "${NC}"
    exit 0
else
    printf '  %s%sTests failed. Implement the port parameterisation changes.%s\n\n' \
        "${RED}" "${BOLD}" "${NC}"
    exit 1
fi
