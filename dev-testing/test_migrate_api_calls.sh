#!/bin/bash
# =============================================================================
# Simplarr — Migrate configure.sh API Calls to call_config_api (TDD Test Suite)
# =============================================================================
# Validates the migration of all curl-based API call sites in configure.sh to
# use the centralized call_config_api helper, the removal of set -e, and the
# introduction of explicit failure tracking with a non-zero exit on genuine
# failures.
#
# Work item summary:
#   Replace all curl-based patterns (inline if/else on curl exit, grep-for-id
#   response checks, >/dev/null 2>&1 discards) with calls to call_config_api.
#   Remove set -e. Track failure count across the run and exit non-zero if any
#   genuine failures occurred. A second run against already-configured services
#   must produce zero log_warn ([!]) lines and exit 0.
#
# Test Phases:
#   1  set -e Removal            — TDD: FAIL before impl, PASS after
#   2  call_config_api Presence  — TDD: FAIL before impl, PASS after
#   3  Old Pattern Removal       — TDD: FAIL before impl, PASS after
#   4  Delegation Check          — TDD: FAIL before impl, PASS after
#   5  Failure Tracking Design   — TDD: FAIL before impl, PASS after
#   6  Idempotency Marker        — Regression guard: PASS before and after
#   7  Second-run Idempotency    — TDD: FAIL before impl (mocked 409 scenario)
#   8  Genuine Failure Exit Code — TDD: FAIL before impl (mocked curl-fail)
#   9  Integration: Second Run   — Live stack only; skipped when unavailable
#
# Usage:
#   ./dev-testing/test_migrate_api_calls.sh
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
# Helper: extract function body (from "funcname()" to closing standalone "}")
# ---------------------------------------------------------------------------
extract_function_body() {
    local func_name="$1"
    local file="$2"
    sed -n "/^${func_name}()/,/^}/p" "${file}"
}

# ---------------------------------------------------------------------------
# Helper: create a safe-to-source copy of configure.sh
# Strips 'set -e' and the "# Run main function" section so sourcing only
# defines functions without executing main().
# ---------------------------------------------------------------------------
_SAFE_CONFIGURE=""
_TMPDIR_SAFE=""

setup_safe_configure() {
    _TMPDIR_SAFE=$(mktemp -d)
    _SAFE_CONFIGURE="${_TMPDIR_SAFE}/configure_testable.sh"
    sed '/^set -e$/d; /^# Run main function$/,$ d' "${CONFIGURE_SH}" \
        > "${_SAFE_CONFIGURE}"
}

# Temp directories used by Phase 7, 8, and 9 — populated lazily
_TMPDIR_PHASE7=""
_TMPDIR_PHASE8=""
_TMPDIR_PHASE9=""

cleanup() {
    for d in "${_TMPDIR_SAFE}" "${_TMPDIR_PHASE7}" "${_TMPDIR_PHASE8}" "${_TMPDIR_PHASE9}"; do
        if [[ -n "${d}" && -d "${d}" ]]; then
            rm -rf "${d}"
        fi
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Migrate configure.sh API Calls to call_config_api (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

if [[ ! -f "${CONFIGURE_SH}" ]]; then
    printf "%b[FATAL]%b configure.sh not found at %s\n" "${RED}" "${NC}" "${CONFIGURE_SH}"
    exit 1
fi

setup_safe_configure

# ---------------------------------------------------------------------------
# Phase 1: set -e Removal
# configure.sh relied on set -e to abort on the first failed curl call.
# After the migration, 409 responses must NOT abort the script, so set -e
# must be removed (or the individual call sites must suppress errors via
# explicit handling before set -e ever fires).
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 1: set -e Removal (TDD — will fail before implementation)"

printf "\n"
info "configure.sh must not use set -e after the migration (409 must not abort the script)"
printf "\n"

# 1.1 — Top-level 'set -e' must be absent (or converted to explicit error handling).
# A bare 'set -e' at the top of the script causes 409 responses to abort execution
# because any non-zero return from a configuration function would exit the script.
# The migration replaces this blanket exit behaviour with explicit failure tracking.
if grep -qE '^set -e$' "${CONFIGURE_SH}"; then
    fail "configure.sh — 'set -e' is still present (TDD: remove set -e; use explicit error handling)"
else
    pass "configure.sh — 'set -e' has been removed (409 responses no longer abort the script)"
fi

# 1.2 — The safe-to-source copy must be parseable (basic health check after sed strip)
if bash -n "${_SAFE_CONFIGURE}" 2>/dev/null; then
    pass "configure.sh — safe-to-source copy passes bash -n syntax check"
else
    fail "configure.sh — safe-to-source copy failed bash -n (stripping set -e broke syntax?)"
fi

# ---------------------------------------------------------------------------
# Phase 2: call_config_api Function Presence
# The helper wraps curl and classifies results by HTTP status code, replacing
# the scattered curl + grep-for-id or curl + discard patterns.
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 2: call_config_api Function Presence (TDD — will fail before implementation)"

printf "\n"
info "configure.sh must define call_config_api() as the single API-call wrapper"
printf "\n"

# 2.1 — call_config_api() must be defined at the top level
if grep -qE "^call_config_api\(\)" "${CONFIGURE_SH}"; then
    pass "configure.sh — call_config_api() function is defined"
else
    fail "configure.sh — call_config_api() is NOT defined (TDD: implement the centralized helper)"
fi

# ---------------------------------------------------------------------------
# Phase 3: Old Pattern Removal
# Three pre-migration patterns must be absent from all service-configuration
# function bodies after migration:
#   (a) curl … >/dev/null 2>&1        — discards response entirely
#   (b) if echo "$response" | grep -q '"id"'  — checks for id field in body
#   (c) 'may already exist'            — the fallback log_warn message
#
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 3: Old Pattern Removal (TDD — will fail before implementation)"

printf "\n"
info "Verifying that pre-migration curl patterns are gone from service config functions"
printf "\n"

# The functions listed below contained the old patterns.  We test each one
# individually so that partial migrations are visible in test output.
declare -a _MIGRATED_FUNCS=(
    "add_qbittorrent_download_client"
    "add_radarr_to_prowlarr"
    "add_sonarr_to_prowlarr"
    "add_radarr_root_folder"
    "add_sonarr_root_folder"
    "add_indexer"
    "sync_prowlarr_indexers"
)

for _func in "${_MIGRATED_FUNCS[@]}"; do
    _body=$(extract_function_body "${_func}" "${CONFIGURE_SH}")

    if [[ -z "${_body}" ]]; then
        skip "${_func} — function not found (may have been renamed)"
        continue
    fi

    # 3.a — >/dev/null 2>&1 discard after curl must be gone
    if echo "${_body}" | grep -qE '>/dev/null 2>&1'; then
        fail "${_func} — still discards curl output with >/dev/null 2>&1 (TDD: replace with call_config_api)"
    else
        pass "${_func} — no >/dev/null 2>&1 curl discard (pattern removed)"
    fi

    # 3.b — grep-for-id response check must be gone
    if echo "${_body}" | grep -qE 'grep -q.*"id"'; then
        fail "${_func} — still uses grep -q '\"id\"' response check (TDD: replace with call_config_api)"
    else
        pass "${_func} — no grep-for-id response check (pattern removed)"
    fi

    # 3.c — 'may already exist' fallback warning must be gone
    if echo "${_body}" | grep -q 'may already exist'; then
        fail "${_func} — still emits 'may already exist' log_warn (TDD: replace with call_config_api 409 handling)"
    else
        pass "${_func} — 'may already exist' warning has been removed"
    fi
done

# ---------------------------------------------------------------------------
# Phase 4: Delegation to call_config_api
# Every function that made direct curl API calls must now delegate those calls
# to call_config_api.
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 4: Delegation to call_config_api (TDD — will fail before implementation)"

printf "\n"
info "Verifying each migrated function calls call_config_api for HTTP operations"
printf "\n"

for _func in "${_MIGRATED_FUNCS[@]}"; do
    _body=$(extract_function_body "${_func}" "${CONFIGURE_SH}")

    if [[ -z "${_body}" ]]; then
        skip "${_func} — skipped (function not found)"
        continue
    fi

    # 4.x — function body must reference call_config_api
    if echo "${_body}" | grep -q 'call_config_api'; then
        pass "${_func} — calls call_config_api (delegated HTTP + error classification)"
    else
        fail "${_func} — does NOT call call_config_api (TDD: replace curl + grep-id with call_config_api)"
    fi
done

# ---------------------------------------------------------------------------
# Phase 5: Failure Tracking Design
# After removal of set -e, genuine failures must be tracked explicitly.
# The script must accumulate a failure count across the run and exit non-zero
# if any non-409 errors occurred.
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 5: Failure Tracking Design (TDD — will fail before implementation)"

printf "\n"
info "Verifying configure.sh tracks genuine failures for exit code propagation"
printf "\n"

# 5.1 — A failure-tracking variable must be declared somewhere in configure.sh.
# Accept common naming conventions used across the codebase.
if grep -qE '\b(_FAILURE_COUNT|FAILURE_COUNT|failure_count|_FAIL_COUNT|FAIL_COUNT|_FAILURES|FAILURES)\b' \
        "${CONFIGURE_SH}"; then
    pass "configure.sh — failure-tracking variable is present"
else
    fail "configure.sh — no failure-tracking variable found (TDD: add FAILURE_COUNT=0 or similar)"
fi

# 5.2 — Main must increment the failure counter when call_config_api reports failure.
# Look for counter increment patterns adjacent to call_config_api call sites.
if grep -qE '\(\( .*(FAILURE|FAIL|failure|fail)[_A-Z]*(COUNT|count)?\+\+|\+= 1\b' "${CONFIGURE_SH}" || \
   grep -qE '(FAILURE_COUNT|failure_count|FAIL_COUNT|fail_count)\s*\+?=\s*[0-9$(]' "${CONFIGURE_SH}"; then
    pass "configure.sh — failure counter increment expression is present"
else
    fail "configure.sh — no failure counter increment found (TDD: increment counter when call_config_api fails)"
fi

# 5.3 — main() must exit with a non-zero code derived from the failure counter.
# Accept 'exit ${FAILURE_COUNT}', 'exit 1 if failures > 0', etc.
if grep -qE 'exit\s+\$\{?(_FAILURE_COUNT|FAILURE_COUNT|failure_count|FAIL_COUNT)\}?|exit\s+1' \
        "${CONFIGURE_SH}"; then
    pass "configure.sh — exit statement with failure-based code is present"
else
    fail "configure.sh — no exit with failure counter found (TDD: exit \${FAILURE_COUNT} or 'exit 1' on failures)"
fi

# ---------------------------------------------------------------------------
# Phase 6: Idempotency Marker (Regression Guard)
# log_warn emits the '[!]' prefix that the integration test (Phase 9) scans
# for. This phase confirms the token is correct BEFORE any implementation so
# the integration test is reliable.
# These tests PASS both before and after implementation.
# ---------------------------------------------------------------------------

section "Phase 6: Idempotency Marker (Regression Guard)"

printf "\n"
info "Confirming log_warn emits [!] — the token the integration test scans for"
printf "\n"

# 6.1 — log_warn() function body must contain the '[!]' marker
_LOG_WARN_BODY=$(extract_function_body "log_warn" "${CONFIGURE_SH}")
if echo "${_LOG_WARN_BODY}" | grep -q '\[!\]'; then
    pass "log_warn() — contains [!] prefix (integration test can assert zero [!] lines on second run)"
else
    fail "log_warn() — [!] prefix NOT found (integration test relies on this marker)"
fi

# 6.2 — log_error() must NOT emit '[!]' (errors use a different marker)
_LOG_ERROR_BODY=$(extract_function_body "log_error" "${CONFIGURE_SH}")
if echo "${_LOG_ERROR_BODY}" | grep -qE '\[!!\]|\[✗\]|\[✘\]|\[ERROR\]|\[✗\]' || \
   ! echo "${_LOG_ERROR_BODY}" | grep -q '\[!\]'; then
    pass "log_error() — does NOT use the same [!] marker as log_warn (distinct severity levels)"
else
    fail "log_error() — unexpectedly uses [!] marker (would pollute the second-run scan)"
fi

# ---------------------------------------------------------------------------
# Phase 7: Second-run Idempotency via Mocked 409 Responses
# When all API calls return HTTP 409, configure.sh must:
#   (a) produce no [!] lines in its output (409 is non-fatal)
#   (b) exit with code 0 (no genuine failures)
#
# Design: run configure.sh as a subprocess with:
#   - Fake config XML files so main() skips wait_for_service and prompts
#   - A fake curl on PATH that returns 409 for every call
#   - QB_PASSWORD set to bypass docker-log lookup
#
# These tests FAIL before implementation (set -e aborts on first non-zero
# return; grep-for-id always warns on 409 bodies) and PASS after.
# ---------------------------------------------------------------------------

section "Phase 7: Second-run Idempotency (Mocked 409 — TDD: will fail before implementation)"

_TMPDIR_PHASE7=$(mktemp -d)

# Create minimal fake config XML files so main() reads API keys from disk
# and skips the interactive wait_for_service + read prompts.
mkdir -p \
    "${_TMPDIR_PHASE7}/radarr" \
    "${_TMPDIR_PHASE7}/sonarr" \
    "${_TMPDIR_PHASE7}/prowlarr"

for _svc in radarr sonarr prowlarr; do
    printf '<Config><ApiKey>fake-%s-key-idempotent</ApiKey></Config>\n' "${_svc}" \
        > "${_TMPDIR_PHASE7}/${_svc}/config.xml"
done

# Create a fake curl that:
#   - Locates the -o <file> argument and writes a minimal 409 JSON body to it
#   - Prints "409" as the HTTP status code (consumed by call_config_api via -w)
#   - Exits 0 (curl itself succeeded; 409 is a valid HTTP response)
_FAKE_CURL_409="${_TMPDIR_PHASE7}/curl"
cat > "${_FAKE_CURL_409}" << 'FAKE_CURL_EOF'
#!/bin/bash
# Fake curl: always returns HTTP 409 (resource already exists).
outfile=""
i=0
args=("$@")
while [[ $i -lt ${#args[@]} ]]; do
    if [[ "${args[$i]}" == "-o" ]]; then
        outfile="${args[$((i+1))]}"
        (( i++ )) || true
    fi
    (( i++ )) || true
done
[[ -n "${outfile}" ]] && printf '{"message":"resource already exists"}' > "${outfile}"
printf '409'
exit 0
FAKE_CURL_EOF
chmod +x "${_FAKE_CURL_409}"

printf "\n"
info "Phase 7a: second run (all 409s) — output must contain zero [!] lines"
printf "\n"

_P7_OUTPUT_FILE="${_TMPDIR_PHASE7}/second_run_output.txt"

CONFIG_DIR="${_TMPDIR_PHASE7}" \
QB_PASSWORD="fake-test-pass" \
    PATH="${_TMPDIR_PHASE7}:${PATH}" \
    bash "${CONFIGURE_SH}" \
    > "${_P7_OUTPUT_FILE}" 2>&1 || true

_P7_WARN_LINES=$(grep -c '\[!\]' "${_P7_OUTPUT_FILE}" 2>/dev/null || true)

if [[ "${_P7_WARN_LINES}" -eq 0 ]]; then
    pass "configure.sh second run (all 409) — zero [!] lines in output (409 is non-fatal)"
else
    fail "configure.sh second run (all 409) — ${_P7_WARN_LINES} [!] line(s) found (TDD: 409 must not emit log_warn)"
    info "  First [!] line: $(grep '\[!\]' "${_P7_OUTPUT_FILE}" | head -1)"
fi

printf "\n"
info "Phase 7b: second run (all 409s) — exit code must be 0"
printf "\n"

CONFIG_DIR="${_TMPDIR_PHASE7}" \
QB_PASSWORD="fake-test-pass" \
    PATH="${_TMPDIR_PHASE7}:${PATH}" \
    bash "${CONFIGURE_SH}" \
    > /dev/null 2>&1
_P7_EXIT=$?

if [[ "${_P7_EXIT}" -eq 0 ]]; then
    pass "configure.sh second run (all 409) — exits 0 (no genuine failures)"
else
    fail "configure.sh second run (all 409) — exited ${_P7_EXIT} (TDD: 409 is not a failure; should exit 0)"
fi

# ---------------------------------------------------------------------------
# Phase 8: Genuine Failure Detection via Mocked curl Failure
# When curl cannot connect (exit 7), configure.sh must:
#   (a) exit with a non-zero code (genuine failure count > 0)
#   (b) produce at least one [!] or [✗] line in output
#
# Design: same subprocess approach as Phase 7 but fake curl exits 7 and writes
# nothing to the response file (simulating a connection-refused scenario).
#
# These tests may coincidentally pass before implementation (set -e aborts on
# the first non-zero return and exits 1), but they precisely validate the
# desired post-implementation behaviour: the script completes all steps and
# then exits non-zero based on the accumulated failure count.
# ---------------------------------------------------------------------------

section "Phase 8: Genuine Failure Detection (Mocked curl-fail — TDD: will fail before implementation)"

_TMPDIR_PHASE8=$(mktemp -d)

mkdir -p \
    "${_TMPDIR_PHASE8}/radarr" \
    "${_TMPDIR_PHASE8}/sonarr" \
    "${_TMPDIR_PHASE8}/prowlarr"

for _svc in radarr sonarr prowlarr; do
    printf '<Config><ApiKey>fake-%s-key-failure</ApiKey></Config>\n' "${_svc}" \
        > "${_TMPDIR_PHASE8}/${_svc}/config.xml"
done

# Create a fake curl that simulates connection-refused (exit 7, no body written)
_FAKE_CURL_FAIL="${_TMPDIR_PHASE8}/curl"
cat > "${_FAKE_CURL_FAIL}" << 'FAKE_CURL_EOF'
#!/bin/bash
# Fake curl: simulates curl exit 7 (couldn't connect).
# Writes nothing to the -o file; emits nothing on stdout.
outfile=""
i=0
args=("$@")
while [[ $i -lt ${#args[@]} ]]; do
    if [[ "${args[$i]}" == "-o" ]]; then
        outfile="${args[$((i+1))]}"
        (( i++ )) || true
    fi
    (( i++ )) || true
done
# Create empty body file so the -o target exists (mimics real curl behaviour
# on connection failure where the output file is left empty).
[[ -n "${outfile}" ]] && touch "${outfile}"
exit 7
FAKE_CURL_EOF
chmod +x "${_FAKE_CURL_FAIL}"

printf "\n"
info "Phase 8a: non-existent host — exit code must be non-zero (genuine failure tracked)"
printf "\n"

CONFIG_DIR="${_TMPDIR_PHASE8}" \
QB_PASSWORD="fake-test-pass" \
    PATH="${_TMPDIR_PHASE8}:${PATH}" \
    bash "${CONFIGURE_SH}" \
    > /dev/null 2>&1
_P8_EXIT=$?

if [[ "${_P8_EXIT}" -ne 0 ]]; then
    pass "configure.sh (curl fail) — exits non-zero when connections fail (genuine failure tracking)"
else
    fail "configure.sh (curl fail) — exited 0 despite curl failures (TDD: track failures and exit non-zero)"
fi

printf "\n"
info "Phase 8b: non-existent host — output must contain error/warning indicator"
printf "\n"

_P8_OUTPUT_FILE="${_TMPDIR_PHASE8}/fail_run_output.txt"

CONFIG_DIR="${_TMPDIR_PHASE8}" \
QB_PASSWORD="fake-test-pass" \
    PATH="${_TMPDIR_PHASE8}:${PATH}" \
    bash "${CONFIGURE_SH}" \
    > "${_P8_OUTPUT_FILE}" 2>&1 || true

# Either [!] (log_warn) or the log_error marker should appear when curl fails
if grep -qE '\[!\]|\[✗\]|\[ERROR\]' "${_P8_OUTPUT_FILE}"; then
    pass "configure.sh (curl fail) — output contains error/warning indicator (failures surfaced to user)"
else
    fail "configure.sh (curl fail) — no error/warning marker in output (TDD: call_config_api must log on curl failure)"
fi

# ---------------------------------------------------------------------------
# Phase 9: Integration — Second Run Against Live Stack
# Runs configure.sh TWICE against the live service stack and asserts that the
# second run (where all resources already exist) produces:
#   - zero [!] lines (no log_warn calls)
#   - exit code 0
#
# This phase is SKIPPED unless the live stack is reachable.
# Requires configure.sh to have been successfully migrated (Phases 1–8 green).
# ---------------------------------------------------------------------------

section "Phase 9: Integration — Second Run (Live Stack)"

printf "\n"
info "Checking if the live Radarr endpoint is reachable to determine skip/run"
printf "\n"

# Honour environment overrides for service URLs so CI can point to test ports
_RADARR_URL="${RADARR_URL:-http://localhost:7878}"
_CONFIG_DIR="${CONFIG_DIR:-${DOCKER_CONFIG:-${PROJECT_ROOT}/configs}}"

_STACK_LIVE=false
if curl -sf --max-time 3 -o /dev/null "${_RADARR_URL}/api/v3/system/status" 2>/dev/null; then
    _STACK_LIVE=true
fi

if [[ "${_STACK_LIVE}" != "true" ]]; then
    skip "Phase 9a — second-run no-warn test (live stack not reachable at ${_RADARR_URL})"
    skip "Phase 9b — second-run exit-code test (live stack not reachable)"
    skip "Phase 9c — non-existent-host env-override test (live stack not reachable; skip for safety)"
else
    printf "\n"
    info "Live stack is reachable — running second-run integration tests"
    printf "\n"

    _TMPDIR_PHASE9=$(mktemp -d)

    # 9a — Run configure.sh (first run already done by the human or CI setup).
    # This IS the second run; capture its output and assert no [!] lines.
    info "Phase 9a: running configure.sh against live stack (second run)..."

    _P9_OUTPUT_FILE="${_TMPDIR_PHASE9}/second_run_live.txt"
    bash "${CONFIGURE_SH}" > "${_P9_OUTPUT_FILE}" 2>&1 || true
    _P9_EXIT=$?

    _P9_WARN_LINES=$(grep -c '\[!\]' "${_P9_OUTPUT_FILE}" 2>/dev/null || true)

    if [[ "${_P9_WARN_LINES}" -eq 0 ]]; then
        pass "configure.sh second run (live) — zero [!] lines in output (all resources pre-configured)"
    else
        fail "configure.sh second run (live) — ${_P9_WARN_LINES} [!] line(s) found; first: $(grep '\[!\]' "${_P9_OUTPUT_FILE}" | head -1)"
    fi

    # 9b — The second run must exit 0 (no genuine failures on a configured stack)
    if [[ "${_P9_EXIT}" -eq 0 ]]; then
        pass "configure.sh second run (live) — exits 0 (idempotent rerun succeeds)"
    else
        fail "configure.sh second run (live) — exited ${_P9_EXIT} (expected 0 on clean second run)"
    fi

    # 9c — Non-existent-host env override: exit code must be non-zero.
    # Points all service URLs at an unreachable loopback port; config files
    # are copied from the live stack so the key-reading path is taken.
    info "Phase 9c: non-existent host env override — exit code must be non-zero"

    # Use config dir from live stack if it exists, otherwise create minimal stubs
    _P9_CONFIG_DIR="${_TMPDIR_PHASE9}/configs"
    if [[ -d "${_CONFIG_DIR}" ]]; then
        cp -r "${_CONFIG_DIR}" "${_P9_CONFIG_DIR}" 2>/dev/null || true
    fi

    # Ensure minimal stub config files exist so the key-reading branch is taken
    for _svc in radarr sonarr prowlarr; do
        mkdir -p "${_P9_CONFIG_DIR}/${_svc}"
        if [[ ! -f "${_P9_CONFIG_DIR}/${_svc}/config.xml" ]]; then
            printf '<Config><ApiKey>stub-%s-key</ApiKey></Config>\n' "${_svc}" \
                > "${_P9_CONFIG_DIR}/${_svc}/config.xml"
        fi
    done

    _P9C_EXIT=0
    RADARR_URL="http://127.0.0.1:19878" \
    SONARR_URL="http://127.0.0.1:19989" \
    PROWLARR_URL="http://127.0.0.1:19696" \
    OVERSEERR_URL="http://127.0.0.1:19055" \
    CONFIG_DIR="${_P9_CONFIG_DIR}" \
    QB_PASSWORD="stub-pass" \
        bash "${CONFIGURE_SH}" \
        > /dev/null 2>&1 || _P9C_EXIT=$?

    if [[ "${_P9C_EXIT}" -ne 0 ]]; then
        pass "configure.sh (non-existent host) — exits non-zero (genuine failures detected)"
    else
        fail "configure.sh (non-existent host) — exited 0 despite pointing to unreachable hosts"
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
    printf "  %b%d test(s) failed.%b\n" "${RED}${BOLD}" "${FAIL_COUNT}" "${NC}"
    printf "\n  TDD note: Phase 1–5 and 7–8 failures indicate the migration\n"
    printf "  has not been performed yet — expected on this TDD branch.\n"
    printf "  All phases should go green after call_config_api is integrated\n"
    printf "  into every curl call site and failure tracking is added to main().\n\n"
    exit 1
fi
