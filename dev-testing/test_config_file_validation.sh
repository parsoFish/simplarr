#!/bin/bash
# =============================================================================
# Simplarr — Config File Structure Validation (TDD Test Suite)
# =============================================================================
# Validates that test.sh Phase 10 asserts the deep structure of service config
# files written by containers after first start.  Mirrors test.ps1 lines
# 853–972.
#
# Services and fields validated:
#   Radarr/Sonarr/Prowlarr  config.xml  — ApiKey (32-char hex), Port, BindAddress, urlBase
#   qBittorrent             qBittorrent.conf — [Preferences] section, WebUI.*= settings
#   Overseerr               settings.json    — valid JSON (python3 -m json.tool / jq)
#   Tautulli                config.ini       — http_port = 8181
#
# Each service block must:
#   - skip when its config file is absent (not fail)
#   - fail when the file is present but required fields are missing
#   - handle missing python3/jq gracefully (skip JSON validation if absent)
#
# Test Phases:
#   1  Prerequisites            — test.sh and test.ps1 must be present
#   2  test.ps1 reference guard — PS1 reference implementation contains all
#                                 expected assertions (regression guard;
#                                 PASS before and after implementation)
#   3  test.sh integration      — test.sh contains Phase 10 with all required
#                                 config-file assertions (TDD: FAIL before
#                                 implementation, PASS after)
#   4  Assertion quality        — skip-on-absent logic is correct; JSON tool
#                                 detection is present; no hard-coded paths
#
# Usage:
#   ./dev-testing/test_config_file_validation.sh
#
# Exit Codes:
#   0 — All tests passed
#   1 — One or more tests failed
#
# No Docker dependency — all assertions are pure grep/awk structural checks
# against test.sh and test.ps1 on disk.
# =============================================================================

set -uo pipefail

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
printf "  Config File Structure Validation (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

TEST_SH="${PROJECT_ROOT}/dev-testing/test.sh"
TEST_PS1="${PROJECT_ROOT}/dev-testing/test.ps1"

# ---------------------------------------------------------------------------
# Phase 1: Prerequisites
# ---------------------------------------------------------------------------

section "Phase 1: Prerequisites"

printf "\n"
info "Verifying test.sh and test.ps1 are present before running assertions"
printf "\n"

_TEST_SH_PRESENT=true
_TEST_PS1_PRESENT=true

if [[ -f "${TEST_SH}" ]]; then
    pass "dev-testing/test.sh — file exists"
else
    fail "dev-testing/test.sh — file missing (cannot run Phase 3 assertions)"
    _TEST_SH_PRESENT=false
fi

if [[ -f "${TEST_PS1}" ]]; then
    pass "dev-testing/test.ps1 — file exists (reference implementation)"
else
    fail "dev-testing/test.ps1 — file missing (cannot run Phase 2 regression guards)"
    _TEST_PS1_PRESENT=false
fi

# ---------------------------------------------------------------------------
# Phase 2: test.ps1 Reference Guard (Regression Guards — PASS before and after)
#
# The PS1 reference implementation (lines 853-972) is the authoritative spec.
# These assertions confirm that the spec has not regressed.  They should PASS
# both before and after the Bash implementation is added to test.sh.
# ---------------------------------------------------------------------------

section "Phase 2: test.ps1 Reference Guard (Regression Guards)"

printf "\n"
info "Verifying test.ps1 contains all expected config-file assertions (reference spec)"
printf "\n"

if [[ "${_TEST_PS1_PRESENT}" != "true" ]]; then
    skip "Phase 2 — test.ps1 not found; all PS1 reference checks skipped"
else
    # 2.1 — Radarr config.xml: Port=7878
    if grep -q '<Port>7878</Port>' "${TEST_PS1}"; then
        pass "test.ps1 — Radarr config.xml: Port=7878 assertion present"
    else
        fail "test.ps1 — Radarr config.xml: Port=7878 assertion MISSING from reference spec"
    fi

    # 2.2 — config.xml: BindAddress assertion
    if grep -q 'BindAddress' "${TEST_PS1}"; then
        pass "test.ps1 — Radarr/Sonarr/Prowlarr config.xml: BindAddress assertion present"
    else
        fail "test.ps1 — config.xml: BindAddress assertion MISSING from reference spec"
    fi

    # 2.3 — Sonarr config.xml: Port=8989
    if grep -q '<Port>8989</Port>' "${TEST_PS1}"; then
        pass "test.ps1 — Sonarr config.xml: Port=8989 assertion present"
    else
        fail "test.ps1 — Sonarr config.xml: Port=8989 assertion MISSING from reference spec"
    fi

    # 2.4 — Prowlarr config.xml: Port=9696
    if grep -q '<Port>9696</Port>' "${TEST_PS1}"; then
        pass "test.ps1 — Prowlarr config.xml: Port=9696 assertion present"
    else
        fail "test.ps1 — Prowlarr config.xml: Port=9696 assertion MISSING from reference spec"
    fi

    # 2.5 — qBittorrent [Preferences] section assertion
    # The PS1 file uses '$qbConf -match "\[Preferences\]"' (PowerShell regex).
    # Use a plain keyword search — BRE mishandles '\[' so a literal keyword is safer.
    if grep -q 'Preferences' "${TEST_PS1}"; then
        pass "test.ps1 — qBittorrent.conf: [Preferences] section assertion present"
    else
        fail "test.ps1 — qBittorrent.conf: [Preferences] assertion MISSING from reference spec"
    fi

    # 2.6 — qBittorrent WebUI assertion
    if grep -q 'WebUI' "${TEST_PS1}"; then
        pass "test.ps1 — qBittorrent.conf: WebUI assertion present"
    else
        fail "test.ps1 — qBittorrent.conf: WebUI assertion MISSING from reference spec"
    fi

    # 2.7 — Overseerr settings.json JSON validity assertion
    if grep -qiE 'settings\.json|ConvertFrom-Json' "${TEST_PS1}"; then
        pass "test.ps1 — Overseerr settings.json: JSON validity assertion present"
    else
        fail "test.ps1 — Overseerr settings.json: JSON validity assertion MISSING from reference spec"
    fi

    # 2.8 — Tautulli config.ini http_port assertion
    if grep -q 'http_port' "${TEST_PS1}"; then
        pass "test.ps1 — Tautulli config.ini: http_port assertion present"
    else
        fail "test.ps1 — Tautulli config.ini: http_port assertion MISSING from reference spec"
    fi

    # 2.9 — Overseerr skip-when-absent behaviour: test.ps1 uses Write-Warn (not Write-Fail)
    # when settings.json does not exist — validated here as a spec invariant.
    # The Write-Warn "not yet created" message appears ~13 lines after $overseerrConfigPath,
    # so use -A15 to capture it reliably.
    if grep -A15 'overseerrConfigPath' "${TEST_PS1}" 2>/dev/null | grep -q 'Write-Warn'; then
        pass "test.ps1 — Overseerr: uses Write-Warn (not Write-Fail) when settings.json absent"
    else
        fail "test.ps1 — Overseerr: expected Write-Warn when settings.json absent — not found in spec"
    fi

    # 2.10 — Tautulli skip-when-absent behaviour: test.ps1 uses Write-Warn
    if grep -A15 'tautulliConfigPath' "${TEST_PS1}" 2>/dev/null | grep -q 'Write-Warn'; then
        pass "test.ps1 — Tautulli: uses Write-Warn (not Write-Fail) when config.ini absent"
    else
        fail "test.ps1 — Tautulli: expected Write-Warn when config.ini absent — not found in spec"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: test.sh Integration (TDD — FAIL before implementation, PASS after)
#
# test.sh must contain a Phase 10 block that validates config file structure
# for all six services.  These assertions FAIL until the phase is added.
#
# Invariants checked:
#   3.1   Phase 10 section header is present in test.sh
#   3.2   Radarr config.xml: ApiKey validation is present
#   3.3   Radarr config.xml: Port=7878 XML tag is validated
#   3.4   config.xml: BindAddress XML tag is validated
#   3.5   Sonarr config.xml: Port=8989 XML tag is validated
#   3.6   BindAddress appears ≥3 times (one per *arr service)
#   3.7   Prowlarr config.xml: Port=9696 XML tag is validated
#   3.8   Prowlarr: Port=9696 and BindAddress appear in proximity
#   3.9   qBittorrent.conf: [Preferences] section is validated
#   3.10  qBittorrent.conf: WebUI setting is validated
#   3.11  Overseerr settings.json: JSON validity checked (python3/jq)
#   3.12  Tautulli config.ini: http_port=8181 validated
#   3.13  Phase 10 adds a new _PHASE8_SUCCESS gate (≥4 occurrences total)
#   3.14  python3/jq absence handled gracefully (command -v check present)
#   3.15  Phase 10 block contains skip() for absent files and fail() for bad files
# ---------------------------------------------------------------------------

section "Phase 3: test.sh Phase 10 Integration (TDD — fails before implementation)"

printf "\n"
info "Verifying test.sh contains Phase 10: Config File Structure Validation"
info "(TDD: these assertions FAIL before Phase 10 is added to test.sh)"
printf "\n"

if [[ "${_TEST_SH_PRESENT}" != "true" ]]; then
    for _check in \
        "3.1 Phase 10 section header" \
        "3.2 Radarr ApiKey validation" \
        "3.3 Radarr Port=7878 XML tag" \
        "3.4 BindAddress XML tag" \
        "3.5 Sonarr Port=8989 XML tag" \
        "3.6 BindAddress ≥3 occurrences" \
        "3.7 Prowlarr Port=9696 XML tag" \
        "3.8 Prowlarr Port+BindAddress proximity" \
        "3.9 qBittorrent [Preferences] fixed-string" \
        "3.10 qBittorrent WebUI" \
        "3.11 Overseerr JSON validation" \
        "3.12 Tautulli http_port=8181" \
        "3.13 Phase 10 adds _PHASE8_SUCCESS gate" \
        "3.14 python3/jq graceful fallback" \
        "3.15 Phase 10 block skip/fail balance"; do
        skip "${_check} — test.sh not found"
    done
else
    # 3.1 — Phase 10 section header must appear in test.sh
    if grep -qE 'Phase 10|phase.*10|10.*[Cc]onfig' "${TEST_SH}"; then
        pass "test.sh — Phase 10 section header is present"
    else
        fail "test.sh — Phase 10 section header MISSING (TDD: add 'Phase 10: Config File Structure Validation')"
    fi

    # 3.2 — Radarr ApiKey validation
    if grep -qE 'ApiKey.*radarr|radarr.*ApiKey' "${TEST_SH}"; then
        pass "test.sh — Radarr config.xml: ApiKey validation present"
    else
        fail "test.sh — Radarr config.xml: ApiKey validation MISSING (TDD: validate <ApiKey> in radarr/config.xml)"
    fi

    # 3.3 — Radarr config.xml: Port=7878 must use the XML tag pattern
    if grep -qF '<Port>7878</Port>' "${TEST_SH}"; then
        pass "test.sh — Radarr config.xml: Port=7878 (<Port>7878</Port>) validation present"
    else
        fail "test.sh — Radarr config.xml: Port=7878 validation MISSING (TDD: grep '<Port>7878</Port>')"
    fi

    # 3.4 — config.xml: BindAddress XML tag
    if grep -qF '<BindAddress>' "${TEST_SH}"; then
        pass "test.sh — config.xml: <BindAddress> tag validation present"
    else
        fail "test.sh — config.xml: <BindAddress> tag validation MISSING (TDD: grep '<BindAddress>')"
    fi

    # 3.5 — Sonarr config.xml: Port=8989 XML tag
    if grep -qF '<Port>8989</Port>' "${TEST_SH}"; then
        pass "test.sh — Sonarr config.xml: Port=8989 (<Port>8989</Port>) validation present"
    else
        fail "test.sh — Sonarr config.xml: Port=8989 validation MISSING (TDD: grep '<Port>8989</Port>')"
    fi

    # 3.6 — BindAddress appears ≥3 times (radarr, sonarr, prowlarr each get their own block)
    _BIND_ADDR_COUNT=$(grep -cF '<BindAddress>' "${TEST_SH}" 2>/dev/null || true)
    if [[ "${_BIND_ADDR_COUNT}" -ge 3 ]]; then
        pass "test.sh — <BindAddress> validation present for all three *arr services (${_BIND_ADDR_COUNT} occurrences)"
    else
        fail "test.sh — <BindAddress> found only ${_BIND_ADDR_COUNT} time(s); expected ≥3 (one per *arr service)"
    fi

    # 3.7 — Prowlarr config.xml: Port=9696 XML tag
    if grep -qF '<Port>9696</Port>' "${TEST_SH}"; then
        pass "test.sh — Prowlarr config.xml: Port=9696 (<Port>9696</Port>) validation present"
    else
        fail "test.sh — Prowlarr config.xml: Port=9696 validation MISSING (TDD: grep '<Port>9696</Port>')"
    fi

    # 3.8 — Prowlarr: Port=9696 and BindAddress appear in proximity (same service block).
    # Sliding-window awk: the two must appear within 20 lines of each other.
    _PROWLARR_BIND=$(awk '
        /<Port>9696/ { window = 20 }
        window > 0 {
            if (/<BindAddress>/) { print "found"; exit }
            window--
        }
        /<BindAddress>/ { window2 = 20 }
        window2 > 0 {
            if (/<Port>9696/) { print "found"; exit }
            window2--
        }
    ' "${TEST_SH}")
    if [[ "${_PROWLARR_BIND}" == "found" ]]; then
        pass "test.sh — Prowlarr config.xml: Port=9696 and <BindAddress> appear in proximity"
    else
        fail "test.sh — Prowlarr config.xml: Port=9696 and <BindAddress> not found in proximity (blocks may be missing)"
    fi

    # 3.9 — qBittorrent.conf: [Preferences] section
    # Use fixed-string (-F) matching: the implementation greps for the literal '[Preferences]'
    # and BRE mishandles the bracket escape '\['.
    if grep -qF '[Preferences]' "${TEST_SH}"; then
        pass "test.sh — qBittorrent.conf: [Preferences] section validation present"
    else
        fail "test.sh — qBittorrent.conf: [Preferences] validation MISSING (TDD: grep -qF '[Preferences]')"
    fi

    # 3.10 — qBittorrent.conf: WebUI setting
    if grep -qE 'WebUI|qbittorrent.*WebUI|WebUI.*qbittorrent' "${TEST_SH}"; then
        pass "test.sh — qBittorrent.conf: WebUI setting validation present"
    else
        fail "test.sh — qBittorrent.conf: WebUI validation MISSING (TDD: grep 'WebUI' in qBittorrent.conf)"
    fi

    # 3.11 — Overseerr settings.json: JSON validity using python3 or jq
    if grep -qE 'python3.*json\.tool|json\.tool.*python3|jq[[:space:]]+\.|jq[[:space:]]+-e' "${TEST_SH}"; then
        pass "test.sh — Overseerr settings.json: JSON validation via python3/jq present"
    else
        fail "test.sh — Overseerr settings.json: JSON validation MISSING (TDD: python3 -m json.tool or jq .)"
    fi

    # 3.12 — Tautulli config.ini: http_port=8181
    if grep -qE 'http_port.*8181|8181.*http_port' "${TEST_SH}"; then
        pass "test.sh — Tautulli config.ini: http_port=8181 validation present"
    else
        fail "test.sh — Tautulli config.ini: http_port=8181 validation MISSING (TDD: grep 'http_port.*8181')"
    fi

    # 3.13 — Phase 10 adds its own _PHASE8_SUCCESS gate.
    # test.sh currently has 3 occurrences (assigned in Phase 8, checked in Phase 9 twice).
    # Phase 10 must add ≥1 more, bringing the total to ≥4.
    _P8_GATE_COUNT=$(grep -c '_PHASE8_SUCCESS' "${TEST_SH}" 2>/dev/null || true)
    if [[ "${_P8_GATE_COUNT}" -ge 4 ]]; then
        pass "test.sh — Phase 10 adds a _PHASE8_SUCCESS gate (${_P8_GATE_COUNT} total occurrences ≥ 4)"
    else
        fail "test.sh — _PHASE8_SUCCESS appears only ${_P8_GATE_COUNT} time(s); Phase 10 needs its own gate (expected ≥4)"
    fi

    # 3.14 — python3/jq absence handled gracefully: must use 'command -v' to detect
    if grep -qE 'command -v python3|command -v jq|which python3|which jq' "${TEST_SH}"; then
        pass "test.sh — python3/jq availability checked before use (graceful fallback)"
    else
        fail "test.sh — python3/jq availability not checked (TDD: use 'command -v python3 || command -v jq')"
    fi

    # 3.15 — Phase 10 block contains both skip() (absent-file) and fail() (malformed-file).
    # Extract the Phase 10 block and verify the balance.
    _PHASE10_BLOCK=$(awk '
        /Phase 10/ { in_phase10 = 1; next }
        in_phase10 && /Phase [0-9]+[^0]/ { exit }
        in_phase10 { print }
    ' "${TEST_SH}" 2>/dev/null || true)

    if [[ -z "${_PHASE10_BLOCK}" ]]; then
        fail "test.sh — Phase 10 block not found; cannot verify skip/fail balance"
    else
        _SKIP_COUNT_P10=$(printf '%s\n' "${_PHASE10_BLOCK}" | grep -c 'skip ' || true)
        if [[ "${_SKIP_COUNT_P10}" -ge 4 ]]; then
            pass "test.sh — Phase 10 block has ${_SKIP_COUNT_P10} skip() calls (≥4 for absent-file branches)"
        else
            fail "test.sh — Phase 10 block has ${_SKIP_COUNT_P10} skip() call(s); expected ≥4 (one per absent config file)"
        fi

        _FAIL_COUNT_P10=$(printf '%s\n' "${_PHASE10_BLOCK}" | grep -c 'fail ' || true)
        if [[ "${_FAIL_COUNT_P10}" -ge 4 ]]; then
            pass "test.sh — Phase 10 block has ${_FAIL_COUNT_P10} fail() calls (≥4 for malformed-file branches)"
        else
            fail "test.sh — Phase 10 block has ${_FAIL_COUNT_P10} fail() call(s); expected ≥4 (one per service field assertion)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Phase 4: Assertion Quality (structural correctness guards)
#
# These checks verify that the implementation uses correct grep patterns and
# handles tool availability robustly.
#
#   4.1  Port patterns: use <Port>NNNN</Port> XML tag
#   4.2  BindAddress pattern: uses <BindAddress> XML tag
#   4.3  config.xml accessed via _TEST_CONFIG_DIR variable (no hard-coded path)
#   4.4  qBittorrent conf accessed via _TEST_CONFIG_DIR variable
#   4.5  Overseerr settings.json accessed via _TEST_CONFIG_DIR variable
#   4.6  Tautulli config.ini accessed via _TEST_CONFIG_DIR variable
#   4.7  urlBase field validated for at least one *arr service
# ---------------------------------------------------------------------------

section "Phase 4: Assertion Quality (structural correctness guards)"

printf "\n"
info "Verifying config-file grep patterns and variable references are correct"
printf "\n"

if [[ "${_TEST_SH_PRESENT}" != "true" ]]; then
    for _check in \
        "4.1 Port XML tag pattern" \
        "4.2 BindAddress XML tag pattern" \
        "4.3 radarr/sonarr/prowlarr config via _TEST_CONFIG_DIR" \
        "4.4 qBittorrent config via _TEST_CONFIG_DIR in Phase 10" \
        "4.5 Overseerr settings.json via _TEST_CONFIG_DIR" \
        "4.6 Tautulli config.ini via _TEST_CONFIG_DIR" \
        "4.7 urlBase field validation"; do
        skip "${_check} — test.sh not found"
    done
else
    # 4.1 — Port XML tag pattern: grep must match <Port>NNNN</Port>
    if grep -qF '<Port>7878</Port>' "${TEST_SH}" && grep -qF '<Port>8989</Port>' "${TEST_SH}"; then
        pass "test.sh — Port validation uses XML tag pattern (<Port>NNNN</Port>)"
    else
        fail "test.sh — Port validation does not use XML tag pattern; bare port number grepping may produce false positives"
    fi

    # 4.2 — BindAddress XML tag: grep must match <BindAddress>
    if grep -qF '<BindAddress>' "${TEST_SH}"; then
        pass "test.sh — BindAddress validation uses XML tag pattern (<BindAddress>...)"
    else
        fail "test.sh — BindAddress validation does not use XML tag pattern"
    fi

    # 4.3 — *arr config.xml files referenced via _TEST_CONFIG_DIR (not hard-coded /tmp)
    if grep -qE '_TEST_CONFIG_DIR.*radarr.*config\.xml|radarr.*_TEST_CONFIG_DIR.*config\.xml' "${TEST_SH}"; then
        pass "test.sh — radarr config.xml accessed via \${_TEST_CONFIG_DIR} variable"
    else
        fail "test.sh — radarr config.xml does not use \${_TEST_CONFIG_DIR}; path may be hard-coded"
    fi

    # 4.4 — qBittorrent conf referenced via _TEST_CONFIG_DIR in the Phase 10 block
    # (Phase 8 also uses it for volume mounts — require it in the Phase 10 context)
    _PHASE10_BLOCK_Q4=$(awk '
        /Phase 10/ { in_phase10 = 1; next }
        in_phase10 && /Phase [0-9]+[^0]/ { exit }
        in_phase10 { print }
    ' "${TEST_SH}" 2>/dev/null || true)

    if printf '%s\n' "${_PHASE10_BLOCK_Q4}" | grep -qE '_TEST_CONFIG_DIR.*qbittorrent|qbittorrent.*_TEST_CONFIG_DIR'; then
        pass "test.sh — Phase 10 block: qBittorrent config accessed via \${_TEST_CONFIG_DIR}"
    else
        fail "test.sh — Phase 10 block: qBittorrent config does not use \${_TEST_CONFIG_DIR}"
    fi

    # 4.5 — Overseerr settings.json referenced via _TEST_CONFIG_DIR
    if grep -qE '_TEST_CONFIG_DIR.*overseerr.*settings\.json|overseerr.*_TEST_CONFIG_DIR.*settings\.json' "${TEST_SH}"; then
        pass "test.sh — Overseerr settings.json accessed via \${_TEST_CONFIG_DIR} variable"
    else
        fail "test.sh — Overseerr settings.json does not use \${_TEST_CONFIG_DIR}"
    fi

    # 4.6 — Tautulli config.ini referenced via _TEST_CONFIG_DIR
    if grep -qE '_TEST_CONFIG_DIR.*tautulli.*config\.ini|tautulli.*_TEST_CONFIG_DIR.*config\.ini' "${TEST_SH}"; then
        pass "test.sh — Tautulli config.ini accessed via \${_TEST_CONFIG_DIR} variable"
    else
        fail "test.sh — Tautulli config.ini does not use \${_TEST_CONFIG_DIR}"
    fi

    # 4.7 — urlBase field: at least one *arr service must validate the urlBase XML field
    if grep -qE 'UrlBase|urlBase|<UrlBase>|<urlBase>' "${TEST_SH}"; then
        pass "test.sh — urlBase field validation present for at least one *arr service"
    else
        fail "test.sh — urlBase field validation MISSING (TDD: grep '<UrlBase>' in *arr config.xml)"
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
    printf "\n  TDD note:\n"
    printf "    Phase 2 failures  — test.ps1 reference spec has regressed; fix the spec first.\n"
    printf "    Phase 3 failures  — Phase 10 not yet added to test.sh; expected before implementation.\n"
    printf "    Phase 4 failures  — Phase 10 exists but uses incorrect patterns or hard-coded paths.\n\n"
    exit 1
fi
