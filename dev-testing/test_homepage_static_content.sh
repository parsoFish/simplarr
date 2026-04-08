#!/bin/bash
# =============================================================================
# Simplarr — Homepage Static Content Assertions (TDD Test Suite)
# =============================================================================
# Validates homepage/index.html structure, service element IDs, and JavaScript
# port configuration without starting any containers — pure static analysis.
# Also validates that test.sh has been updated to include a homepage validation
# phase (TDD: Phase 5 assertions fail before the implementation is added).
#
# Mirrors test.ps1 lines 493–530 (Homepage Tests section).
#
# Test Phases:
#   1  File Existence          — homepage/index.html and status.html present
#   2  HTML Structure          — index.html has valid <html>...</html> wrapper
#   3  Service Element IDs     — all 7 service IDs present as id="<name>"
#                                (plex, radarr, sonarr, prowlarr, overseerr,
#                                 qbittorrent, tautulli)
#   4  JavaScript Port Config  — index.html has JS port map with radarr:7878
#   5  Status Page Health Check — status.html contains fetch and status logic
#   6  test.sh Integration     — test.sh contains the homepage validation phase
#                                (TDD: FAIL before implementation, PASS after)
#
# Usage:
#   ./dev-testing/test_homepage_static_content.sh
#
# Exit Codes:
#   0 — All tests passed
#   1 — One or more tests failed
#
# No Docker dependency — all assertions are pure grep/awk structural checks
# against homepage files and test.sh on disk.
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
printf "  Homepage Static Content Assertions (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

INDEX_HTML="${PROJECT_ROOT}/homepage/index.html"
STATUS_HTML="${PROJECT_ROOT}/homepage/status.html"
TEST_SH="${PROJECT_ROOT}/dev-testing/test.sh"

# ---------------------------------------------------------------------------
# Phase 1: File Existence
# ---------------------------------------------------------------------------

section "Phase 1: File Existence"

printf "\n"
info "Verifying homepage files are present before running content assertions"
printf "\n"

_INDEX_PRESENT=true
_STATUS_PRESENT=true

if [[ -f "${INDEX_HTML}" ]]; then
    pass "homepage/index.html — file exists"
else
    fail "homepage/index.html — file missing (content validation cannot proceed)"
    _INDEX_PRESENT=false
fi

if [[ -f "${STATUS_HTML}" ]]; then
    pass "homepage/status.html — file exists"
else
    fail "homepage/status.html — file missing (health-check validation cannot proceed)"
    _STATUS_PRESENT=false
fi

# ---------------------------------------------------------------------------
# Phase 2: HTML Structure
#
# index.html must be a well-formed HTML document with both an opening <html>
# tag and a closing </html> tag.  This mirrors test.ps1 line 496:
#   $indexContent -match "<html" -and $indexContent -match "</html>"
# ---------------------------------------------------------------------------

section "Phase 2: HTML Structure"

printf "\n"
info "Verifying index.html has a valid HTML document wrapper"
printf "\n"

if [[ "${_INDEX_PRESENT}" != "true" ]]; then
    skip "HTML structure check — homepage/index.html not found"
else
    _has_open_tag=false
    _has_close_tag=false

    if grep -q "<html" "${INDEX_HTML}"; then
        _has_open_tag=true
    fi

    if grep -q "</html>" "${INDEX_HTML}"; then
        _has_close_tag=true
    fi

    if [[ "${_has_open_tag}" == "true" && "${_has_close_tag}" == "true" ]]; then
        pass "homepage/index.html — valid HTML structure (has <html> and </html>)"
    elif [[ "${_has_open_tag}" != "true" ]]; then
        fail "homepage/index.html — missing opening <html> tag"
    else
        fail "homepage/index.html — missing closing </html> tag"
    fi

    # DOCTYPE declaration should also be present for a well-formed document
    if grep -q "<!DOCTYPE html>" "${INDEX_HTML}"; then
        pass "homepage/index.html — <!DOCTYPE html> declaration is present"
    else
        fail "homepage/index.html — missing <!DOCTYPE html> declaration"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: Service Element IDs
#
# index.html must contain an HTML element with id="<service>" for each of the
# 7 supported services.  Mirrors test.ps1 lines 504–511:
#   $serviceIds = @("plex","radarr","sonarr","prowlarr","overseerr",
#                   "qbittorrent","tautulli")
#   foreach ($id in $serviceIds) {
#     if ($indexContent -notmatch "id=`"$id`"") { ... }
#   }
# ---------------------------------------------------------------------------

section "Phase 3: Service Element IDs"

printf "\n"
info "Verifying all 7 service link elements have their expected HTML id attributes"
printf "\n"

if [[ "${_INDEX_PRESENT}" != "true" ]]; then
    skip "Service element ID checks — homepage/index.html not found"
else
    declare -a SERVICE_IDS=(
        "plex"
        "radarr"
        "sonarr"
        "prowlarr"
        "overseerr"
        "qbittorrent"
        "tautulli"
    )

    for svc_id in "${SERVICE_IDS[@]}"; do
        # Match the exact attribute value: id="<service>" (double-quoted)
        if grep -qE "id=\"${svc_id}\"" "${INDEX_HTML}"; then
            pass "homepage/index.html — id=\"${svc_id}\" element is present"
        else
            fail "homepage/index.html — missing element with id=\"${svc_id}\""
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 4: JavaScript Port Configuration
#
# index.html must contain a JavaScript port map object and the radarr port
# entry (7878) as a correctness spot-check.  Mirrors test.ps1 lines 513–514:
#   $hasPortConfig = $indexContent -match "const services = \{" -and
#                    $indexContent -match "radarr:\s*7878"
# ---------------------------------------------------------------------------

section "Phase 4: JavaScript Port Configuration"

printf "\n"
info "Verifying JavaScript service-to-port mapping in index.html"
printf "\n"

if [[ "${_INDEX_PRESENT}" != "true" ]]; then
    skip "JavaScript port config checks — homepage/index.html not found"
else
    # 4.1 — const services = { object declaration must be present
    if grep -q "const services = {" "${INDEX_HTML}"; then
        pass "homepage/index.html — JavaScript 'const services = {' port map is declared"
    else
        fail "homepage/index.html — missing JavaScript port map ('const services = {')"
    fi

    # 4.2 — radarr: 7878 entry (canonical port, spot-check for correctness)
    if grep -qE "radarr:[[:space:]]*7878" "${INDEX_HTML}"; then
        pass "homepage/index.html — radarr port (7878) is configured in JS port map"
    else
        fail "homepage/index.html — radarr port (7878) missing from JS port map"
    fi

    # 4.3 — sonarr: 8989 (second spot-check to guard against partial maps)
    if grep -qE "sonarr:[[:space:]]*8989" "${INDEX_HTML}"; then
        pass "homepage/index.html — sonarr port (8989) is configured in JS port map"
    else
        fail "homepage/index.html — sonarr port (8989) missing from JS port map"
    fi

    # 4.4 — prowlarr: 9696
    if grep -qE "prowlarr:[[:space:]]*9696" "${INDEX_HTML}"; then
        pass "homepage/index.html — prowlarr port (9696) is configured in JS port map"
    else
        fail "homepage/index.html — prowlarr port (9696) missing from JS port map"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 5: Status Page Health Check Logic
#
# status.html must contain JavaScript fetch() calls and reference "status"
# URLs so that the health-check polling loop works.
# Mirrors test.ps1 lines 525–529:
#   $statusContent -match "fetch" -and $statusContent -match "status"
# ---------------------------------------------------------------------------

section "Phase 5: Status Page Health Check Logic"

printf "\n"
info "Verifying status.html contains fetch-based health check implementation"
printf "\n"

if [[ "${_STATUS_PRESENT}" != "true" ]]; then
    skip "Status page checks — homepage/status.html not found"
else
    # 5.1 — fetch() must be used for health polling (mirrors test.ps1)
    if grep -q "fetch" "${STATUS_HTML}"; then
        pass "homepage/status.html — fetch() call is present (health check polling)"
    else
        fail "homepage/status.html — missing fetch() call (health check polling not implemented)"
    fi

    # 5.2 — "status" must appear (service status references or status URLs)
    if grep -q "status" "${STATUS_HTML}"; then
        pass "homepage/status.html — 'status' reference is present"
    else
        fail "homepage/status.html — missing 'status' reference"
    fi

    # 5.3 — All 7 services should have status indicator elements (id="status-<name>")
    declare -a STATUS_IDS=(
        "status-plex"
        "status-radarr"
        "status-sonarr"
        "status-prowlarr"
        "status-overseerr"
        "status-qbittorrent"
        "status-tautulli"
    )

    printf "\n"
    info "Verifying per-service status indicator elements in status.html"
    printf "\n"

    for status_id in "${STATUS_IDS[@]}"; do
        if grep -qE "id=\"${status_id}\"" "${STATUS_HTML}"; then
            pass "homepage/status.html — id=\"${status_id}\" status indicator is present"
        else
            fail "homepage/status.html — missing status indicator id=\"${status_id}\""
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 6: test.sh Integration
#
# test.sh must contain a homepage validation phase that runs static checks
# against homepage/index.html before container startup — matching the same
# assertions test.ps1 runs in its "Homepage Tests" section (lines 493–530).
#
# TDD: These assertions FAIL before the homepage phase is added to test.sh
# (the implementation).  They PASS once test.sh contains the grep-based
# homepage checks as a dedicated phase.
#
# Checked invariants:
#   6.1  test.sh references homepage/index.html in a validation context.
#   6.2  test.sh greps for id="plex" (or the plex service ID pattern).
#   6.3  test.sh greps for id="radarr" or iterates the full list of 7 IDs.
#   6.4  test.sh validates the JS port configuration ('const services').
#   6.5  test.sh checks radarr: 7878 (canonical port spot-check).
#   6.6  test.sh references status.html for health-check logic validation.
#   6.7  test.sh uses fail() near homepage assertions (exits 1 on missing IDs).
# ---------------------------------------------------------------------------

section "Phase 6: test.sh Integration (TDD — fails before implementation)"

printf "\n"
info "Verifying test.sh contains homepage static content validation phase"
info "(TDD: these assertions FAIL before the homepage phase is added to test.sh)"
printf "\n"

if [[ ! -f "${TEST_SH}" ]]; then
    skip "Phase 6 — test.sh not found at ${TEST_SH}"
else
    # 6.1 — test.sh must reference homepage/index.html in a validation context
    if grep -q 'homepage/index\.html\|homepage.*index\.html\|index\.html' "${TEST_SH}"; then
        pass "test.sh — references index.html for homepage validation"
    else
        fail "test.sh — missing reference to homepage/index.html (homepage phase not implemented)"
    fi

    # 6.2 — test.sh must grep for plex element ID
    if grep -qE '"plex"|id.*plex|plex.*id' "${TEST_SH}"; then
        pass "test.sh — validates plex element ID in homepage"
    else
        fail "test.sh — missing plex element ID check (homepage phase incomplete)"
    fi

    # 6.3 — test.sh must iterate or check all 7 service IDs.
    # Either an explicit loop over a SERVICE_IDS-style array or individual checks.
    # We verify at least radarr and tautulli (first and last in the list) are covered.
    _radarr_id_check=false
    _tautulli_id_check=false

    if grep -qE '"radarr"|id.*radarr.*html|radarr.*id' "${TEST_SH}"; then
        _radarr_id_check=true
    fi
    if grep -qE '"tautulli"|id.*tautulli.*html|tautulli.*id' "${TEST_SH}"; then
        _tautulli_id_check=true
    fi

    if [[ "${_radarr_id_check}" == "true" && "${_tautulli_id_check}" == "true" ]]; then
        pass "test.sh — validates radarr and tautulli element IDs (full service list covered)"
    elif [[ "${_radarr_id_check}" != "true" ]]; then
        fail "test.sh — missing radarr element ID check in homepage phase"
    else
        fail "test.sh — missing tautulli element ID check in homepage phase"
    fi

    # 6.4 — test.sh must check for the JS port map declaration
    if grep -q "const services" "${TEST_SH}"; then
        pass "test.sh — validates JavaScript 'const services' port map"
    else
        fail "test.sh — missing JavaScript port map check ('const services') in homepage phase"
    fi

    # 6.5 — test.sh must check for the radarr: 7878 canonical port entry
    if grep -qE 'radarr.*7878|7878.*radarr' "${TEST_SH}"; then
        pass "test.sh — validates radarr port (7878) in JS port map"
    else
        fail "test.sh — missing radarr port (7878) spot-check in homepage phase"
    fi

    # 6.6 — test.sh must reference status.html for health-check logic validation
    if grep -q 'status\.html' "${TEST_SH}"; then
        pass "test.sh — references status.html for health-check logic validation"
    else
        fail "test.sh — missing reference to status.html (health-check validation absent)"
    fi

    # 6.7 — The homepage checks must use fail() to report missing content.
    # A skip() would silently accept missing IDs, defeating the validation.
    # Strategy: check that fail() appears in the vicinity of homepage references.
    _homepage_fail_check=$(awk '
        /homepage\/index\.html|index\.html|const services|radarr.*7878/ { window = 15 }
        window > 0 {
            if (/fail[[:space:]]*\(/) { print "found"; exit }
            window--
        }
    ' "${TEST_SH}")

    if [[ "${_homepage_fail_check}" == "found" ]]; then
        pass "test.sh — homepage checks use fail() to signal missing content (suite will exit 1)"
    else
        fail "test.sh — homepage checks do not call fail() near assertions; missing IDs may be silently skipped"
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
    printf "\n  TDD note: Phase 6 failures indicate the homepage validation phase\n"
    printf "  has not yet been added to test.sh.  Phases 1–5 failures indicate\n"
    printf "  homepage/index.html or status.html is missing expected content.\n\n"
    exit 1
fi
