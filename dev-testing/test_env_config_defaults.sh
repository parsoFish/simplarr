#!/bin/bash
# =============================================================================
# Simplarr — .env.example Config Defaults Validation (TDD Test Suite)
# =============================================================================
# Validates that .env.example exists as a canonical reference for all
# configurable values: service port numbers, container paths, and wait/retry
# parameters.  This is a documentation artefact test — no containers are
# started.
#
# Test Phases:
#   1  File Existence        — .env.example is present at the project root
#   2  Bash Parseability     — bash -n and source succeed without errors
#   3  Port Defaults         — all 7 service port variables present with
#                              canonical default values
#   4  Container Paths       — MOVIES_PATH, TV_PATH, DOWNLOADS_PATH present
#   5  Wait / Retry Params   — WAIT_MAX_ATTEMPTS=30 and WAIT_RETRY_SECS=2
#   6  Variable Name Parity  — key names in .env.example match those used in
#                              configure.sh and setup.sh (the "subsequent items"
#                              the work item refers to)
#   7  No Secrets            — .env.example contains no actual credentials
#                              (passwords, tokens) — only placeholder values
#
# TDD: ALL Phase 2–7 assertions FAIL on the current codebase (.env.example
# does not exist).  They PASS once the file is created.
#
# Usage:
#   ./dev-testing/test_env_config_defaults.sh
#
# Exit Codes:
#   0 — All tests passed
#   1 — One or more tests failed
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
CONFIGURE_SH="${PROJECT_ROOT}/configure.sh"
SETUP_SH="${PROJECT_ROOT}/setup.sh"

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
printf "  .env.example Config Defaults Validation (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

# ---------------------------------------------------------------------------
# Phase 1: File Existence
# ---------------------------------------------------------------------------

section "Phase 1: File Existence"

printf "\n"
info "Verifying .env.example is present at the project root"
printf "\n"

_ENV_PRESENT=true

if [[ -f "${ENV_EXAMPLE}" ]]; then
    pass ".env.example — file exists"
else
    fail ".env.example — file missing at ${ENV_EXAMPLE}"
    _ENV_PRESENT=false
fi

# ---------------------------------------------------------------------------
# Phase 2: Bash Parseability
#
# .env.example must be valid shell syntax so that:
#   a) bash -n validates it as syntactically correct
#   b) it can be sourced by setup scripts and CI helpers to obtain defaults
#
# TDD: FAIL until .env.example exists; PASS once created.
# ---------------------------------------------------------------------------

section "Phase 2: Bash Parseability"

printf "\n"
info "Verifying .env.example is parseable by bash"
printf "\n"

if [[ "${_ENV_PRESENT}" != "true" ]]; then
    skip "bash parseability — .env.example not found"
    skip "source safety — .env.example not found"
else
    # 2.1 — bash -n: syntax check only (no execution)
    SYNTAX_ERR=""
    if SYNTAX_ERR=$(bash -n "${ENV_EXAMPLE}" 2>&1); then
        pass ".env.example — bash -n reports no syntax errors"
    else
        fail ".env.example — bash -n syntax error: ${SYNTAX_ERR}"
    fi

    # 2.2 — Source in a subshell: verify it can be sourced without side-effects.
    # A well-formed .env.example only contains KEY=value assignments and
    # comments; it must not run commands or produce output when sourced.
    SOURCE_OUTPUT=""
    SOURCE_ERR=""
    if SOURCE_OUTPUT=$(bash -c "source '${ENV_EXAMPLE}' 2>&1" 2>&1); then
        if [[ -z "${SOURCE_OUTPUT}" ]]; then
            pass ".env.example — sources cleanly with no output (pure assignments)"
        else
            fail ".env.example — produced unexpected output when sourced: ${SOURCE_OUTPUT}"
        fi
    else
        SOURCE_ERR="${SOURCE_OUTPUT}"
        fail ".env.example — failed to source: ${SOURCE_ERR}"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: Port Defaults
#
# The canonical service port numbers that ALL subsequent work items reference.
# Each variable must be present and set to the correct default value.
#
# Canonical defaults:
#   RADARR_PORT=7878      (Radarr)
#   SONARR_PORT=8989      (Sonarr)
#   PROWLARR_PORT=9696    (Prowlarr)
#   QBITTORRENT_PORT=8080 (qBittorrent)
#   OVERSEERR_PORT=5055   (Overseerr)
#   TAUTULLI_PORT=8181    (Tautulli)
#   PLEX_PORT=32400       (Plex)
#
# TDD: FAIL until .env.example has all 7 port entries.
# ---------------------------------------------------------------------------

section "Phase 3: Port Defaults"

printf "\n"
info "Asserting all 7 service port variables with canonical default values"
printf "\n"

if [[ "${_ENV_PRESENT}" != "true" ]]; then
    skip "port defaults — .env.example not found"
else
    # Parallel arrays: variable name → expected default value
    declare -a PORT_VARS=(
        "RADARR_PORT"
        "SONARR_PORT"
        "PROWLARR_PORT"
        "QBITTORRENT_PORT"
        "OVERSEERR_PORT"
        "TAUTULLI_PORT"
        "PLEX_PORT"
    )
    declare -a PORT_DEFAULTS=(
        "7878"
        "8989"
        "9696"
        "8080"
        "5055"
        "8181"
        "32400"
    )

    for i in "${!PORT_VARS[@]}"; do
        _var="${PORT_VARS[$i]}"
        _val="${PORT_DEFAULTS[$i]}"

        # 3.N — key must be declared in the file
        if grep -qE "^[[:space:]]*${_var}=" "${ENV_EXAMPLE}"; then
            pass ".env.example — ${_var} key is declared"
        else
            fail ".env.example — ${_var} key is missing (expected ${_var}=${_val})"
            continue
        fi

        # 3.N — key must be set to the canonical default (not empty, not wrong)
        if grep -qE "^[[:space:]]*${_var}=${_val}([[:space:]]|$)" "${ENV_EXAMPLE}"; then
            pass ".env.example — ${_var}=${_val} (canonical default)"
        else
            _actual=$(grep -E "^[[:space:]]*${_var}=" "${ENV_EXAMPLE}" | head -1)
            fail ".env.example — ${_var} has wrong default (expected ${_val}): ${_actual}"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 4: Container Path Variables
#
# Configure scripts use these paths to tell *arr services where media lives
# inside the container.  They must be declared in .env.example so operators
# can override them without modifying scripts.
#
# Required: MOVIES_PATH, TV_PATH, DOWNLOADS_PATH
# ---------------------------------------------------------------------------

section "Phase 4: Container Path Variables"

printf "\n"
info "Asserting MOVIES_PATH, TV_PATH, and DOWNLOADS_PATH are declared"
printf "\n"

if [[ "${_ENV_PRESENT}" != "true" ]]; then
    skip "container path variables — .env.example not found"
else
    declare -a PATH_VARS=("MOVIES_PATH" "TV_PATH" "DOWNLOADS_PATH")

    for _var in "${PATH_VARS[@]}"; do
        # 4.N — key must be declared (value is operator-specific, not checked)
        if grep -qE "^[[:space:]]*${_var}=" "${ENV_EXAMPLE}"; then
            pass ".env.example — ${_var} key is declared"
        else
            fail ".env.example — ${_var} key is missing"
            continue
        fi

        # 4.N — value, if set, must look like an absolute path (starts with /)
        _line=$(grep -E "^[[:space:]]*${_var}=" "${ENV_EXAMPLE}" | head -1)
        _value="${_line#*=}"
        # Strip inline comments and surrounding whitespace
        _value="${_value%%#*}"
        _value="${_value//[[:space:]]/}"
        if [[ -n "${_value}" ]]; then
            if [[ "${_value}" == /* ]]; then
                pass ".env.example — ${_var}=${_value} (absolute path, valid container path)"
            else
                fail ".env.example — ${_var}=${_value} does not look like an absolute path (expected /…)"
            fi
        else
            # Empty value is allowed — operator must fill it in
            pass ".env.example — ${_var} is declared (empty placeholder — operator must set)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 5: Wait / Retry Parameters
#
# configure.sh hard-codes max_attempts=30 and sleep 2 inside wait_for_service().
# .env.example must expose these as overridable variables (WAIT_MAX_ATTEMPTS
# and WAIT_RETRY_SECS) so CI environments can tune them without code changes.
#
# Canonical defaults: WAIT_MAX_ATTEMPTS=30, WAIT_RETRY_SECS=2
# ---------------------------------------------------------------------------

section "Phase 5: Wait / Retry Parameters"

printf "\n"
info "Asserting WAIT_MAX_ATTEMPTS=30 and WAIT_RETRY_SECS=2 are declared"
printf "\n"

if [[ "${_ENV_PRESENT}" != "true" ]]; then
    skip "wait/retry parameters — .env.example not found"
else
    # 5.1 — WAIT_MAX_ATTEMPTS must be declared with default 30
    if grep -qE "^[[:space:]]*WAIT_MAX_ATTEMPTS=" "${ENV_EXAMPLE}"; then
        pass ".env.example — WAIT_MAX_ATTEMPTS key is declared"
        if grep -qE "^[[:space:]]*WAIT_MAX_ATTEMPTS=30([[:space:]]|$)" "${ENV_EXAMPLE}"; then
            pass ".env.example — WAIT_MAX_ATTEMPTS=30 (matches configure.sh max_attempts default)"
        else
            _actual=$(grep -E "^[[:space:]]*WAIT_MAX_ATTEMPTS=" "${ENV_EXAMPLE}" | head -1)
            fail ".env.example — WAIT_MAX_ATTEMPTS has wrong default (expected 30): ${_actual}"
        fi
    else
        fail ".env.example — WAIT_MAX_ATTEMPTS key is missing (expected WAIT_MAX_ATTEMPTS=30)"
    fi

    # 5.2 — WAIT_RETRY_SECS must be declared with default 2
    if grep -qE "^[[:space:]]*WAIT_RETRY_SECS=" "${ENV_EXAMPLE}"; then
        pass ".env.example — WAIT_RETRY_SECS key is declared"
        if grep -qE "^[[:space:]]*WAIT_RETRY_SECS=2([[:space:]]|$)" "${ENV_EXAMPLE}"; then
            pass ".env.example — WAIT_RETRY_SECS=2 (matches configure.sh sleep interval)"
        else
            _actual=$(grep -E "^[[:space:]]*WAIT_RETRY_SECS=" "${ENV_EXAMPLE}" | head -1)
            fail ".env.example — WAIT_RETRY_SECS has wrong default (expected 2): ${_actual}"
        fi
    else
        fail ".env.example — WAIT_RETRY_SECS key is missing (expected WAIT_RETRY_SECS=2)"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 6: Variable Name Parity with configure.sh and setup.sh
#
# The variable names defined in .env.example are the "agreed names" that all
# subsequent items reference.  If a name in .env.example does not appear in
# configure.sh or setup.sh, either:
#   a) the name is wrong and needs to be corrected, or
#   b) the implementation scripts have not yet been updated (future work item)
#
# We test names that the work item explicitly lists as the canonical reference
# for subsequent items: port names (already used by config.json.template) and
# container paths (already used by configure.sh).
# ---------------------------------------------------------------------------

section "Phase 6: Variable Name Parity with configure.sh / setup.sh"

printf "\n"

if [[ "${_ENV_PRESENT}" != "true" ]]; then
    skip "variable name parity — .env.example not found"
else
    # 6a: Port variable names must be present in configure.sh or
    # config.json.template (these are the "subsequent items" that use them).

    CONFIG_TEMPLATE="${PROJECT_ROOT}/homepage/config.json.template"

    printf "\n"
    info "Port variable names vs. homepage/config.json.template (envsubst tokens)"
    printf "\n"

    if [[ -f "${CONFIG_TEMPLATE}" ]]; then
        declare -a TEMPLATE_PORT_VARS=(
            "RADARR_PORT"
            "SONARR_PORT"
            "PROWLARR_PORT"
            "QBITTORRENT_PORT"
            "OVERSEERR_PORT"
            "TAUTULLI_PORT"
            "PLEX_PORT"
        )

        for _var in "${TEMPLATE_PORT_VARS[@]}"; do
            if grep -q "${_var}" "${CONFIG_TEMPLATE}"; then
                pass "config.json.template — uses \${${_var}} (name matches .env.example)"
            else
                fail "config.json.template — \${${_var}} not found (name mismatch with .env.example?)"
            fi
        done
    else
        skip "config.json.template parity — file not found"
    fi

    # 6b: Container path variable names must match configure.sh usage.
    # configure.sh already uses MOVIES_PATH, TV_PATH, DOWNLOADS_PATH.

    printf "\n"
    info "Container path variable names vs. configure.sh"
    printf "\n"

    if [[ -f "${CONFIGURE_SH}" ]]; then
        declare -a CONFIGURE_PATH_VARS=("MOVIES_PATH" "TV_PATH" "DOWNLOADS_PATH")

        for _var in "${CONFIGURE_PATH_VARS[@]}"; do
            if grep -q "${_var}" "${CONFIGURE_SH}"; then
                pass "configure.sh — uses \${${_var}} (name matches .env.example)"
            else
                fail "configure.sh — \${${_var}} not found (name mismatch or configure.sh not updated)"
            fi
        done
    else
        skip "configure.sh path parity — configure.sh not found"
    fi

    # 6c: WAIT_MAX_ATTEMPTS / WAIT_RETRY_SECS are new canonical names; they
    # do NOT yet appear in configure.sh (that's a subsequent work item).
    # We assert they do NOT conflict with any existing variable defined in
    # configure.sh (i.e. a different name for the same concept).

    printf "\n"
    info "Wait/retry params — verifying no conflicting local hard-codes in configure.sh"
    printf "\n"

    if [[ -f "${CONFIGURE_SH}" ]]; then
        # configure.sh currently hard-codes 'local max_attempts=30' inside
        # wait_for_service(). Confirm this number matches the .env.example default
        # so that when configure.sh is updated to read WAIT_MAX_ATTEMPTS, the
        # default behaviour is unchanged.
        if grep -qE "max_attempts=30" "${CONFIGURE_SH}"; then
            pass "configure.sh — hard-coded max_attempts=30 matches WAIT_MAX_ATTEMPTS=30 default"
        else
            fail "configure.sh — max_attempts default differs from WAIT_MAX_ATTEMPTS=30 in .env.example"
        fi

        # configure.sh uses 'sleep 2' inside wait_for_service() — must match WAIT_RETRY_SECS=2.
        if grep -qE "sleep[[:space:]]+2" "${CONFIGURE_SH}"; then
            pass "configure.sh — hard-coded sleep 2 matches WAIT_RETRY_SECS=2 default"
        else
            fail "configure.sh — sleep interval differs from WAIT_RETRY_SECS=2 in .env.example"
        fi
    else
        skip "configure.sh wait-param cross-check — configure.sh not found"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 7: No Secrets in .env.example
#
# .env.example is committed to version control.  It must not contain real
# credentials.  Passwords and tokens must be empty or placeholder values only.
#
# Checks:
#   - Any PASSWORD= line must not have a non-empty, non-placeholder value
#   - Any TOKEN= line must not have a non-empty, non-placeholder value
#   - PLEX_CLAIM= (the only known secret-adjacent field) must be empty or
#     a placeholder like "claim-XXXXXX" (the real token is time-limited anyway)
# ---------------------------------------------------------------------------

section "Phase 7: No Secrets — Placeholder Values Only"

printf "\n"
info "Asserting that password/token fields contain only placeholders"
printf "\n"

if [[ "${_ENV_PRESENT}" != "true" ]]; then
    skip "secrets check — .env.example not found"
else
    # 7.1 — PASSWORD fields must be empty or placeholder (not a real password)
    # A real password would be a non-empty value that is not all X's, not
    # "changeme", "your-password", "placeholder", or similar known stubs.
    _pw_count=$(grep -cE "^[[:space:]]*[A-Z_]*PASSWORD[A-Z_]*=[^[:space:]]" "${ENV_EXAMPLE}" || true)
    if [[ "${_pw_count}" -eq 0 ]]; then
        pass ".env.example — no PASSWORD field has a non-empty value (safe to commit)"
    else
        # Tolerate if all non-empty values are obviously placeholders
        _real_pw=$(grep -E "^[[:space:]]*[A-Z_]*PASSWORD[A-Z_]*=[^[:space:]]" "${ENV_EXAMPLE}" \
            | grep -vE "=(\"|')(change-?me|your-?password|placeholder|xxxx|<[^>]+>|CHANGE_ME)(\"|')?$" \
            | grep -vE "=change-?me$|=your-?password$|=placeholder$|=<[^>]+>$" \
            || true)
        if [[ -n "${_real_pw}" ]]; then
            fail ".env.example — PASSWORD field has a non-placeholder value (do not commit secrets)"
        else
            pass ".env.example — PASSWORD fields contain only recognized placeholders"
        fi
    fi

    # 7.2 — TOKEN fields must be empty or placeholder
    _token_count=$(grep -cE "^[[:space:]]*[A-Z_]*TOKEN[A-Z_]*=[^[:space:]]" "${ENV_EXAMPLE}" || true)
    if [[ "${_token_count}" -eq 0 ]]; then
        pass ".env.example — no TOKEN field has a non-empty value (safe to commit)"
    else
        _real_token=$(grep -E "^[[:space:]]*[A-Z_]*TOKEN[A-Z_]*=[^[:space:]]" "${ENV_EXAMPLE}" \
            | grep -vE "=claim-[Xx]+$|=<[^>]+>$|=your-token$" \
            || true)
        if [[ -n "${_real_token}" ]]; then
            fail ".env.example — TOKEN field has a non-placeholder value (do not commit secrets)"
        else
            pass ".env.example — TOKEN fields contain only recognized placeholders"
        fi
    fi

    # 7.3 — PLEX_CLAIM specifically: must be empty or a stub; real claim tokens
    # start with "claim-" followed by a 24+ character alphanumeric string.
    if grep -qE "^[[:space:]]*PLEX_CLAIM=" "${ENV_EXAMPLE}"; then
        _plex_val=$(grep -E "^[[:space:]]*PLEX_CLAIM=" "${ENV_EXAMPLE}" | head -1)
        _plex_val="${_plex_val#*=}"
        _plex_val="${_plex_val%%#*}"
        _plex_val="${_plex_val//[[:space:]]/}"
        # A real claim token is "claim-" + 24+ alphanumerics
        if echo "${_plex_val}" | grep -qE "^claim-[A-Za-z0-9]{24,}$"; then
            fail ".env.example — PLEX_CLAIM appears to contain a real token (do not commit secrets)"
        else
            pass ".env.example — PLEX_CLAIM is empty or a placeholder (not a real token)"
        fi
    fi

    # 7.4 — Overall: no line should contain a value that looks like a real
    # secret (long hex/base64 strings that appear in real API keys)
    _suspicious=$(grep -E "^[[:space:]]*[A-Z_]*(KEY|SECRET|TOKEN|PASSWORD)[A-Z_]*=[a-f0-9]{32,}" \
        "${ENV_EXAMPLE}" || true)
    if [[ -n "${_suspicious}" ]]; then
        fail ".env.example — suspicious hex/token value found (may be a real secret): ${_suspicious}"
    else
        pass ".env.example — no suspicious long hex/token values found"
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
    printf "\n  TDD note: failures indicate .env.example does not yet exist or\n"
    printf "  is missing required variable definitions.  Implementation checklist:\n"
    printf "\n"
    printf "    1. Create .env.example at the project root\n"
    printf "    2. Add port defaults:\n"
    printf "         RADARR_PORT=7878\n"
    printf "         SONARR_PORT=8989\n"
    printf "         PROWLARR_PORT=9696\n"
    printf "         QBITTORRENT_PORT=8080\n"
    printf "         OVERSEERR_PORT=5055\n"
    printf "         TAUTULLI_PORT=8181\n"
    printf "         PLEX_PORT=32400\n"
    printf "    3. Add container paths: MOVIES_PATH, TV_PATH, DOWNLOADS_PATH\n"
    printf "    4. Add wait/retry params: WAIT_MAX_ATTEMPTS=30, WAIT_RETRY_SECS=2\n"
    printf "    5. Use placeholder (empty or stub) values for any secret fields\n"
    printf "\n"
    exit 1
fi
