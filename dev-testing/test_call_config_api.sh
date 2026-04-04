#!/bin/bash
# =============================================================================
# Simplarr — call_config_api Helper Validation (TDD Test Suite)
# =============================================================================
# Validates the call_config_api() helper function for configure.sh.
#
# The helper wraps curl to capture body and status code separately, then
# classifies the result with the same logic as the PowerShell equivalent:
#
#   200/201 → log_success
#   409     → log_info "Already configured"
#   4xx/5xx → log_warn with code and body
#   curl failure (non-zero exit) → log_error
#
# Test Phases:
#   1  Function presence         — TDD: FAIL before impl, PASS after
#   2  Structural analysis       — TDD: FAIL before impl, PASS after
#   3  Behavior (mocked curl)    — TDD: FAIL before impl, PASS after
#
# Usage:
#   ./dev-testing/test_call_config_api.sh
#
# Exit Codes:
#   0 — All tests passed
#   1 — One or more tests failed
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
printf "  call_config_api Helper Validation (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

if [[ ! -f "${CONFIGURE_SH}" ]]; then
    printf "%b[FATAL]%b configure.sh not found at %s\n" "${RED}" "${NC}" "${CONFIGURE_SH}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: create a safe-to-source copy of configure.sh
# Removes 'set -e' (prevents unintended exits in test harness) and strips the
# bottom "main "$@"" invocation so sourcing only defines functions.
# ---------------------------------------------------------------------------
_SAFE_CONFIGURE=""
_TMPDIR_SAFE=""

setup_safe_configure() {
    _TMPDIR_SAFE=$(mktemp -d)
    _SAFE_CONFIGURE="${_TMPDIR_SAFE}/configure_testable.sh"
    sed '/^set -e$/d; /^# Run main function$/,$ d' "${CONFIGURE_SH}" \
        > "${_SAFE_CONFIGURE}"
}

cleanup() {
    if [[ -n "${_TMPDIR_SAFE}" && -d "${_TMPDIR_SAFE}" ]]; then
        rm -rf "${_TMPDIR_SAFE}"
    fi
    if [[ -n "${_TMPDIR_PHASE3:-}" && -d "${_TMPDIR_PHASE3}" ]]; then
        rm -rf "${_TMPDIR_PHASE3}"
    fi
}
trap cleanup EXIT

setup_safe_configure

# ---------------------------------------------------------------------------
# Phase 1: Function Presence
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 1: Function Presence (TDD — will fail before implementation)"

printf "\n"
info "Checking for call_config_api() function in configure.sh"
printf "\n"

# 1.1 — call_config_api() must be defined at the top level of configure.sh
if grep -qE "^call_config_api\(\)" "${CONFIGURE_SH}"; then
    pass "configure.sh — call_config_api() function is defined"
else
    fail "configure.sh — call_config_api() is NOT defined (TDD: implement the helper)"
fi

# ---------------------------------------------------------------------------
# Phase 2: Structural Analysis
# These tests FAIL before implementation and PASS after.
# Validates that the function uses the correct curl pattern and references
# all required log functions — before any runtime execution.
# ---------------------------------------------------------------------------

section "Phase 2: Structural Analysis (TDD — will fail before implementation)"

printf "\n"
info "Verifying call_config_api() body uses curl -o/-w and references all log levels"
printf "\n"

_FUNC_BODY=""
if grep -qE "^call_config_api\(\)" "${CONFIGURE_SH}"; then
    _FUNC_BODY=$(sed -n '/^call_config_api()/,/^}/p' "${CONFIGURE_SH}")
fi

# 2.1 — Must use curl with -o flag to capture body to a temp file
if echo "${_FUNC_BODY}" | grep -qE 'curl.*-[[:alpha:]]*o[[:alpha:]]* |-o '; then
    pass "call_config_api() — uses curl -o to capture response body to a file"
else
    fail "call_config_api() — does NOT use curl -o flag (TDD: use 'curl -s -o <file> -w \"%{http_code}\"')"
fi

# 2.2 — Must capture the HTTP status code via %{http_code}
if echo "${_FUNC_BODY}" | grep -q '%{http_code}'; then
    pass "call_config_api() — captures HTTP status code via curl -w \"%{http_code}\""
else
    fail "call_config_api() — does NOT use %{http_code} format string (TDD: capture status separately)"
fi

# 2.3 — Must explicitly handle curl exit code rather than relying on set -e
# The function must inspect $? or use 'if !', '||', or a saved exit variable
if echo "${_FUNC_BODY}" | grep -qE '(if !.*curl|\bcurl_exit\b|\bcurl_rc\b|curl.*&&|curl.*\|\||! http_code=)'; then
    pass "call_config_api() — explicitly handles curl exit code (no implicit set -e reliance)"
else
    fail "call_config_api() — does NOT explicitly handle curl exit code (TDD: check exit code, remove set -e guard)"
fi

# 2.4 — Must reference log_success for 200/201 cases
if echo "${_FUNC_BODY}" | grep -q 'log_success'; then
    pass "call_config_api() — references log_success (for HTTP 200/201 success cases)"
else
    fail "call_config_api() — does NOT reference log_success (TDD: call log_success on 200/201)"
fi

# 2.5 — Must reference log_info for the 409 "Already configured" case
if echo "${_FUNC_BODY}" | grep -q 'log_info'; then
    pass "call_config_api() — references log_info (for 409 Already configured case)"
else
    fail "call_config_api() — does NOT reference log_info (TDD: call log_info on 409)"
fi

# 2.6 — Must reference log_warn for 4xx/5xx error codes
if echo "${_FUNC_BODY}" | grep -q 'log_warn'; then
    pass "call_config_api() — references log_warn (for 4xx/5xx error cases)"
else
    fail "call_config_api() — does NOT reference log_warn (TDD: call log_warn on 4xx/5xx)"
fi

# 2.7 — Must reference log_error for curl connection failures
if echo "${_FUNC_BODY}" | grep -q 'log_error'; then
    pass "call_config_api() — references log_error (for curl failure/network error)"
else
    fail "call_config_api() — does NOT reference log_error (TDD: call log_error on curl non-zero exit)"
fi

# 2.8 — Must have an explicit 409 branch (not lumped with generic 4xx)
if echo "${_FUNC_BODY}" | grep -q '409'; then
    pass "call_config_api() — contains explicit 409 branch (separate from generic 4xx)"
else
    fail "call_config_api() — no explicit 409 branch found (TDD: treat 409 distinctly as 'Already configured')"
fi

# ---------------------------------------------------------------------------
# Phase 3: Behavior via Mocked curl
# Runtime tests using a bash-level curl override (no real network calls).
# These tests FAIL before implementation (function missing) and PASS after.
#
# Design:
#   Each sub-test runs in an isolated subshell that:
#     1. Sources the safe configure.sh to get all function definitions
#     2. Overrides log_* functions AFTER source to intercept log calls
#     3. Overrides curl to return a controlled status code / body / exit code
#     4. Calls call_config_api and captures its stdout+stderr to a file
#   We then assert the correct log level and message content in the capture.
#
# Log markers emitted by overridden log_* functions:
#   log_success → "LOG_LEVEL=SUCCESS"
#   log_info    → "LOG_LEVEL=INFO"
#   log_warn    → "LOG_LEVEL=WARN"
#   log_error   → "LOG_LEVEL=ERROR"
# ---------------------------------------------------------------------------

section "Phase 3: Behavior via Mocked curl (TDD — will fail before implementation)"

_TMPDIR_PHASE3=$(mktemp -d)

# Guard: check if call_config_api can be sourced before running behavioral tests
_FUNC_EXISTS=false
if bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1
    declare -f call_config_api > /dev/null 2>&1
" 2>/dev/null; then
    _FUNC_EXISTS=true
fi

if [[ "${_FUNC_EXISTS}" != "true" ]]; then
    fail "call_config_api() — function not available after sourcing configure.sh (TDD: implementation required)"
    skip "Phase 3a — HTTP 201 behavior test skipped (function not found)"
    skip "Phase 3b — HTTP 200 behavior test skipped (function not found)"
    skip "Phase 3c — HTTP 409 behavior test skipped (function not found)"
    skip "Phase 3d — HTTP 400 behavior test skipped (function not found)"
    skip "Phase 3e — HTTP 500 behavior test skipped (function not found)"
    skip "Phase 3f — curl failure behavior test skipped (function not found)"
else

# ---------------------------------------------------------------------------
# Phase 3a: HTTP 201 Created → log_success, no log_warn or log_error
# ---------------------------------------------------------------------------
printf "\n"
info "Phase 3a: HTTP 201 Created → log_success"
printf "\n"

_CAP_201="${_TMPDIR_PHASE3}/out_201.txt"

bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

    # Override log functions AFTER source so they intercept calls from call_config_api
    log_success() { printf 'LOG_LEVEL=SUCCESS MSG=%s\n' \"\$*\"; }
    log_info()    { printf 'LOG_LEVEL=INFO MSG=%s\n' \"\$*\"; }
    log_warn()    { printf 'LOG_LEVEL=WARN MSG=%s\n' \"\$*\"; }
    log_error()   { printf 'LOG_LEVEL=ERROR MSG=%s\n' \"\$*\"; }

    curl() {
        local i=0
        local -a args=(\"\$@\")
        local outfile=''
        while [[ \$i -lt \${#args[@]} ]]; do
            if [[ \"\${args[\$i]}\" == '-o' ]]; then
                outfile=\"\${args[\$((i+1))]}\"
                (( i++ )) || true
            fi
            (( i++ )) || true
        done
        [[ -n \"\${outfile}\" ]] && printf '{\"id\":42}' > \"\${outfile}\"
        printf '201'
        return 0
    }

    call_config_api 'POST' 'http://mock-radarr:7878/api/v3/downloadclient' 'test-key-abc' '{}' \
        > '${_CAP_201}' 2>&1 || true
" 2>/dev/null

if [[ ! -f "${_CAP_201}" || ! -s "${_CAP_201}" ]]; then
    fail "call_config_api(201) — no log output captured (function may not have executed)"
else
    if grep -q 'LOG_LEVEL=SUCCESS' "${_CAP_201}"; then
        pass "call_config_api(201) — log_success called on HTTP 201"
    else
        fail "call_config_api(201) — log_success NOT called; got: $(cat "${_CAP_201}")"
    fi
    if ! grep -qE 'LOG_LEVEL=WARN|LOG_LEVEL=ERROR' "${_CAP_201}"; then
        pass "call_config_api(201) — log_warn and log_error NOT called (correct for 201)"
    else
        fail "call_config_api(201) — unexpected log_warn or log_error on HTTP 201"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3b: HTTP 200 OK → log_success, no log_warn or log_error
# ---------------------------------------------------------------------------
printf "\n"
info "Phase 3b: HTTP 200 OK → log_success"
printf "\n"

_CAP_200="${_TMPDIR_PHASE3}/out_200.txt"

bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

    log_success() { printf 'LOG_LEVEL=SUCCESS MSG=%s\n' \"\$*\"; }
    log_info()    { printf 'LOG_LEVEL=INFO MSG=%s\n' \"\$*\"; }
    log_warn()    { printf 'LOG_LEVEL=WARN MSG=%s\n' \"\$*\"; }
    log_error()   { printf 'LOG_LEVEL=ERROR MSG=%s\n' \"\$*\"; }

    curl() {
        local i=0
        local -a args=(\"\$@\")
        local outfile=''
        while [[ \$i -lt \${#args[@]} ]]; do
            if [[ \"\${args[\$i]}\" == '-o' ]]; then
                outfile=\"\${args[\$((i+1))]}\"
                (( i++ )) || true
            fi
            (( i++ )) || true
        done
        [[ -n \"\${outfile}\" ]] && printf '{\"id\":1}' > \"\${outfile}\"
        printf '200'
        return 0
    }

    call_config_api 'PUT' 'http://mock-sonarr:8989/api/v3/rootfolder' 'sonarr-key-xyz' '{}' \
        > '${_CAP_200}' 2>&1 || true
" 2>/dev/null

if [[ ! -f "${_CAP_200}" || ! -s "${_CAP_200}" ]]; then
    fail "call_config_api(200) — no log output captured"
else
    if grep -q 'LOG_LEVEL=SUCCESS' "${_CAP_200}"; then
        pass "call_config_api(200) — log_success called on HTTP 200"
    else
        fail "call_config_api(200) — log_success NOT called; got: $(cat "${_CAP_200}")"
    fi
    if ! grep -qE 'LOG_LEVEL=WARN|LOG_LEVEL=ERROR' "${_CAP_200}"; then
        pass "call_config_api(200) — log_warn and log_error NOT called (correct for 200)"
    else
        fail "call_config_api(200) — unexpected log_warn or log_error on HTTP 200"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3c: HTTP 409 Conflict → log_info containing "Already", no warn/error
# 409 means the resource already exists — this is non-fatal and expected
# during idempotent re-runs of the configuration script.
# ---------------------------------------------------------------------------
printf "\n"
info "Phase 3c: HTTP 409 Conflict → log_info 'Already configured' (non-fatal)"
printf "\n"

_CAP_409="${_TMPDIR_PHASE3}/out_409.txt"

bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

    log_success() { printf 'LOG_LEVEL=SUCCESS MSG=%s\n' \"\$*\"; }
    log_info()    { printf 'LOG_LEVEL=INFO MSG=%s\n' \"\$*\"; }
    log_warn()    { printf 'LOG_LEVEL=WARN MSG=%s\n' \"\$*\"; }
    log_error()   { printf 'LOG_LEVEL=ERROR MSG=%s\n' \"\$*\"; }

    curl() {
        local i=0
        local -a args=(\"\$@\")
        local outfile=''
        while [[ \$i -lt \${#args[@]} ]]; do
            if [[ \"\${args[\$i]}\" == '-o' ]]; then
                outfile=\"\${args[\$((i+1))]}\"
                (( i++ )) || true
            fi
            (( i++ )) || true
        done
        [[ -n \"\${outfile}\" ]] && printf '{\"message\":\"already exists\"}' > \"\${outfile}\"
        printf '409'
        return 0
    }

    call_config_api 'POST' 'http://mock-radarr:7878/api/v3/downloadclient' 'test-key-abc' '{}' \
        > '${_CAP_409}' 2>&1 || true
" 2>/dev/null

if [[ ! -f "${_CAP_409}" || ! -s "${_CAP_409}" ]]; then
    fail "call_config_api(409) — no log output captured"
else
    if grep -q 'LOG_LEVEL=INFO' "${_CAP_409}"; then
        pass "call_config_api(409) — log_info called on HTTP 409"
    else
        fail "call_config_api(409) — log_info NOT called; got: $(cat "${_CAP_409}")"
    fi
    # The message must say "Already configured" (case-insensitive match on "already")
    if grep -qi 'already' "${_CAP_409}"; then
        pass "call_config_api(409) — log_info message contains 'Already configured'"
    else
        fail "call_config_api(409) — log_info message does NOT contain 'Already' text"
    fi
    # 409 is NOT an error — no warn or error should be logged
    if ! grep -qE 'LOG_LEVEL=WARN|LOG_LEVEL=ERROR' "${_CAP_409}"; then
        pass "call_config_api(409) — log_warn and log_error NOT called (409 is non-fatal)"
    else
        fail "call_config_api(409) — unexpected log_warn or log_error on HTTP 409 (should be non-fatal)"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3d: HTTP 400 Bad Request → log_warn containing status code and body
# ---------------------------------------------------------------------------
printf "\n"
info "Phase 3d: HTTP 400 Bad Request → log_warn with status code and response body"
printf "\n"

_CAP_400="${_TMPDIR_PHASE3}/out_400.txt"

bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

    log_success() { printf 'LOG_LEVEL=SUCCESS MSG=%s\n' \"\$*\"; }
    log_info()    { printf 'LOG_LEVEL=INFO MSG=%s\n' \"\$*\"; }
    log_warn()    { printf 'LOG_LEVEL=WARN MSG=%s\n' \"\$*\"; }
    log_error()   { printf 'LOG_LEVEL=ERROR MSG=%s\n' \"\$*\"; }

    curl() {
        local i=0
        local -a args=(\"\$@\")
        local outfile=''
        while [[ \$i -lt \${#args[@]} ]]; do
            if [[ \"\${args[\$i]}\" == '-o' ]]; then
                outfile=\"\${args[\$((i+1))]}\"
                (( i++ )) || true
            fi
            (( i++ )) || true
        done
        [[ -n \"\${outfile}\" ]] && printf '{\"error\":\"bad_request_details\"}' > \"\${outfile}\"
        printf '400'
        return 0
    }

    call_config_api 'POST' 'http://mock-radarr:7878/api/v3/downloadclient' 'test-key-abc' '{}' \
        > '${_CAP_400}' 2>&1 || true
" 2>/dev/null

if [[ ! -f "${_CAP_400}" || ! -s "${_CAP_400}" ]]; then
    fail "call_config_api(400) — no log output captured"
else
    if grep -q 'LOG_LEVEL=WARN' "${_CAP_400}"; then
        pass "call_config_api(400) — log_warn called on HTTP 400 (4xx = client error)"
    else
        fail "call_config_api(400) — log_warn NOT called; got: $(cat "${_CAP_400}")"
    fi
    # Warn message must include the status code so the user knows what went wrong
    if grep -q '400' "${_CAP_400}"; then
        pass "call_config_api(400) — log_warn message contains status code '400'"
    else
        fail "call_config_api(400) — log_warn message does NOT contain status code '400'"
    fi
    # Warn message must include the response body for diagnosis
    if grep -q 'bad_request_details' "${_CAP_400}"; then
        pass "call_config_api(400) — log_warn message contains response body content"
    else
        fail "call_config_api(400) — log_warn message does NOT include response body (needed for diagnosis)"
    fi
    if ! grep -qE 'LOG_LEVEL=SUCCESS|LOG_LEVEL=ERROR' "${_CAP_400}"; then
        pass "call_config_api(400) — log_success and log_error NOT called (400 is warn-only)"
    else
        fail "call_config_api(400) — unexpected log_success or log_error on HTTP 400"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3e: HTTP 500 Server Error → log_warn containing status code and body
# ---------------------------------------------------------------------------
printf "\n"
info "Phase 3e: HTTP 500 Server Error → log_warn with status code and response body"
printf "\n"

_CAP_500="${_TMPDIR_PHASE3}/out_500.txt"

bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

    log_success() { printf 'LOG_LEVEL=SUCCESS MSG=%s\n' \"\$*\"; }
    log_info()    { printf 'LOG_LEVEL=INFO MSG=%s\n' \"\$*\"; }
    log_warn()    { printf 'LOG_LEVEL=WARN MSG=%s\n' \"\$*\"; }
    log_error()   { printf 'LOG_LEVEL=ERROR MSG=%s\n' \"\$*\"; }

    curl() {
        local i=0
        local -a args=(\"\$@\")
        local outfile=''
        while [[ \$i -lt \${#args[@]} ]]; do
            if [[ \"\${args[\$i]}\" == '-o' ]]; then
                outfile=\"\${args[\$((i+1))]}\"
                (( i++ )) || true
            fi
            (( i++ )) || true
        done
        [[ -n \"\${outfile}\" ]] && printf '{\"error\":\"internal_server_error_detail\"}' > \"\${outfile}\"
        printf '500'
        return 0
    }

    call_config_api 'POST' 'http://mock-radarr:7878/api/v3/downloadclient' 'test-key-abc' '{}' \
        > '${_CAP_500}' 2>&1 || true
" 2>/dev/null

if [[ ! -f "${_CAP_500}" || ! -s "${_CAP_500}" ]]; then
    fail "call_config_api(500) — no log output captured"
else
    if grep -q 'LOG_LEVEL=WARN' "${_CAP_500}"; then
        pass "call_config_api(500) — log_warn called on HTTP 500 (5xx = server error)"
    else
        fail "call_config_api(500) — log_warn NOT called; got: $(cat "${_CAP_500}")"
    fi
    if grep -q '500' "${_CAP_500}"; then
        pass "call_config_api(500) — log_warn message contains status code '500'"
    else
        fail "call_config_api(500) — log_warn message does NOT contain status code '500'"
    fi
    if grep -q 'internal_server_error_detail' "${_CAP_500}"; then
        pass "call_config_api(500) — log_warn message contains response body content"
    else
        fail "call_config_api(500) — log_warn message does NOT include response body (needed for diagnosis)"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3f: curl failure (non-zero exit) → log_error, no success/warn
# Simulates a connection-refused or DNS-failure scenario where curl itself
# fails before receiving any HTTP response.
# ---------------------------------------------------------------------------
printf "\n"
info "Phase 3f: curl failure (non-zero exit code) → log_error"
printf "\n"

_CAP_CURL_FAIL="${_TMPDIR_PHASE3}/out_curl_fail.txt"

bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

    log_success() { printf 'LOG_LEVEL=SUCCESS MSG=%s\n' \"\$*\"; }
    log_info()    { printf 'LOG_LEVEL=INFO MSG=%s\n' \"\$*\"; }
    log_warn()    { printf 'LOG_LEVEL=WARN MSG=%s\n' \"\$*\"; }
    log_error()   { printf 'LOG_LEVEL=ERROR MSG=%s\n' \"\$*\"; }

    # Simulates curl exit 7 (couldn't connect): writes nothing to the body file,
    # emits no http_code on stdout, returns non-zero.
    curl() {
        local i=0
        local -a args=(\"\$@\")
        local outfile=''
        while [[ \$i -lt \${#args[@]} ]]; do
            if [[ \"\${args[\$i]}\" == '-o' ]]; then
                outfile=\"\${args[\$((i+1))]}\"
                (( i++ )) || true
            fi
            (( i++ )) || true
        done
        # Intentionally write nothing to outfile — connection never established
        [[ -n \"\${outfile}\" ]] && touch \"\${outfile}\"
        return 7
    }

    call_config_api 'POST' 'http://unreachable-host:7878/api/v3/downloadclient' 'test-key-abc' '{}' \
        > '${_CAP_CURL_FAIL}' 2>&1 || true
" 2>/dev/null

if [[ ! -f "${_CAP_CURL_FAIL}" || ! -s "${_CAP_CURL_FAIL}" ]]; then
    fail "call_config_api(curl_fail) — no log output captured (function may not have run)"
else
    if grep -q 'LOG_LEVEL=ERROR' "${_CAP_CURL_FAIL}"; then
        pass "call_config_api(curl_fail) — log_error called when curl exits non-zero"
    else
        fail "call_config_api(curl_fail) — log_error NOT called; got: $(cat "${_CAP_CURL_FAIL}")"
    fi
    if ! grep -qE 'LOG_LEVEL=SUCCESS|LOG_LEVEL=WARN' "${_CAP_CURL_FAIL}"; then
        pass "call_config_api(curl_fail) — log_success and log_warn NOT called (correct for curl failure)"
    else
        fail "call_config_api(curl_fail) — unexpected log_success or log_warn on curl failure"
    fi
fi

fi  # end _FUNC_EXISTS guard

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
    printf "  %b%d test(s) failed.%b\n" "${RED}${BOLD}" "${FAIL_COUNT}" "${NC}"
    printf "\n  TDD note: Phase 1, 2, and 3 failures mean the implementation\n"
    printf "  has not been written yet — expected before the feature branch.\n"
    printf "  All phases should go green after call_config_api() is implemented.\n\n"
    exit 1
fi
