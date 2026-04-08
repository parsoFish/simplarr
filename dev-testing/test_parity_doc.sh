#!/bin/bash
# =============================================================================
# Test Parity Coverage Map Document Tests (Bash)
# =============================================================================
# Validates that docs/dev-testing/test-parity.md exists and contains a
# complete mapping of every test.ps1 phase to its test.sh equivalent,
# with explicit N/A justifications for any phases without a Bash counterpart.
#
# Acceptance criteria (from work item wi-simplarr-023):
#   - Document exists and is non-empty (smoke test)
#   - Every test.ps1 phase header has a corresponding entry (covered or N/A)
#   - PSParser syntax check is explicitly noted as having no Bash equivalent
#   - Homepage Tests phase is explicitly noted as having no Bash equivalent
#   - All 9 test.sh phases appear in the document
#   - Document contains a phase mapping table (test.ps1 ↔ test.sh)
#   - Each N/A entry includes a justification (not just "N/A")
#
# TDD: This script is written BEFORE the document exists. All tests MUST fail
# on the current codebase until docs/dev-testing/test-parity.md is created.
#
# Usage:
#   ./dev-testing/test_parity_doc.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOC_FILE="${PROJECT_ROOT}/docs/dev-testing/test-parity.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
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
    printf "  %b[PASS]%b %s\n" "${GREEN}" "${NC}" "$1"
    (( PASS_COUNT++ )) || true
}

fail() {
    printf "  %b[FAIL]%b %s\n" "${RED}" "${NC}" "$1"
    (( FAIL_COUNT++ )) || true
}

info() {
    printf "  %b[INFO]%b %s\n" "${BLUE}" "${NC}" "$1"
}

section() {
    printf "\n%b%s%b\n" "${BOLD}${CYAN}" "$1" "${NC}"
    printf "%b%s%b\n" "${CYAN}" "────────────────────────────────────────────────────────────" "${NC}"
}

# Returns 0 if extended regex pattern is found in the document (case-sensitive)
doc_contains() {
    grep -qE "$1" "${DOC_FILE}" 2>/dev/null
}

# Returns 0 if extended regex pattern is found in the document (case-insensitive)
doc_contains_i() {
    grep -qiE "$1" "${DOC_FILE}" 2>/dev/null
}

# Returns the line number of the first match, or empty if not found
doc_line_of() {
    # shellcheck disable=SC2317
    grep -nE "$1" "${DOC_FILE}" 2>/dev/null | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Test Parity Coverage Map — Document Tests\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

# ---------------------------------------------------------------------------
# Section 1: Smoke test — file exists and is non-empty
# ---------------------------------------------------------------------------

section "Smoke Test: File Existence and Content"

if [[ -f "${DOC_FILE}" ]]; then
    pass "docs/dev-testing/test-parity.md exists"
else
    fail "docs/dev-testing/test-parity.md does not exist (expected at: ${DOC_FILE})"
    printf "\n%bCannot continue: the parity document is missing.%b\n" "${RED}" "${NC}"
    printf "  Create docs/dev-testing/test-parity.md and re-run.\n\n"
    printf "  %d passed, %d failed\n\n" "${PASS_COUNT}" "${FAIL_COUNT}"
    exit 1
fi

DOC_SIZE=$(wc -c < "${DOC_FILE}" 2>/dev/null || echo "0")
info "Document size: ${DOC_SIZE} bytes"

if [[ "${DOC_SIZE}" -gt 0 ]]; then
    pass "docs/dev-testing/test-parity.md is non-empty"
else
    fail "docs/dev-testing/test-parity.md exists but is empty"
    printf "\n%bCannot continue: the parity document is empty.%b\n\n" "${RED}" "${NC}"
    printf "  %d passed, %d failed\n\n" "${PASS_COUNT}" "${FAIL_COUNT}"
    exit 1
fi

LINE_COUNT=$(wc -l < "${DOC_FILE}" 2>/dev/null || echo "0")
info "Document line count: ${LINE_COUNT}"

if [[ "${LINE_COUNT}" -ge 20 ]]; then
    pass "docs/dev-testing/test-parity.md has sufficient content (>= 20 lines)"
else
    fail "docs/dev-testing/test-parity.md is too short (${LINE_COUNT} lines; expected >= 20)"
fi

# ---------------------------------------------------------------------------
# Section 2: Phase mapping table is present
# ---------------------------------------------------------------------------

section "Phase Mapping Table"

# The document must contain a markdown table header row referencing both scripts
if doc_contains "\|.*test\.ps1.*\|.*test\.sh.*\||test\.ps1.*\|.*test\.sh"; then
    pass "Document contains a phase mapping table (test.ps1 | test.sh columns)"
else
    fail "Document must contain a phase mapping table with 'test.ps1' and 'test.sh' columns"
fi

# The table must use markdown table syntax (pipe-delimited rows)
if doc_contains "^\|.*\|.*\|"; then
    pass "Document uses markdown table syntax (pipe-delimited rows)"
else
    fail "Document must use markdown pipe-table syntax for the phase mapping"
fi

# ---------------------------------------------------------------------------
# Section 3: All test.ps1 phases are covered
# ---------------------------------------------------------------------------
# test.ps1 phases (in order of appearance, by Write-Header calls):
#   1. Pre-flight Checks
#   2. File Existence Tests
#   3. Syntax Validation Tests          (includes PSParser for .ps1 files)
#   4. Nginx Configuration Tests
#   5. Template Configuration Tests
#   6. Setup Script Validation Tests
#   7. Configure Script Validation Tests
#   8. Homepage Tests
#   9. Container Startup Tests
#  10. Service Connectivity Tests
#  11. API Integration Tests
#  12. Configuration File Validation Tests
#  13. Configure Script Functionality Tests
#  14. Verification Tests

section "test.ps1 Phases: Coverage Entries"

declare -a PS1_PHASES=(
    "Pre-flight|Preflight"
    "File Existence"
    "Syntax Validation"
    "Nginx Configuration"
    "Template Configuration|qBittorrent"
    "Setup Script Validation|Setup Script"
    "Configure Script Validation|Configure Script"
    "Homepage"
    "Container Startup"
    "Service Connectivity|Connectivity"
    "API Integration"
    "Configuration File Validation"
    "Configure Script Functionality"
    "Verification"
)

declare -a PS1_PHASE_LABELS=(
    "Pre-flight Checks"
    "File Existence Tests"
    "Syntax Validation Tests"
    "Nginx Configuration Tests"
    "Template Configuration Tests"
    "Setup Script Validation Tests"
    "Configure Script Validation Tests"
    "Homepage Tests"
    "Container Startup Tests"
    "Service Connectivity Tests"
    "API Integration Tests"
    "Configuration File Validation Tests"
    "Configure Script Functionality Tests"
    "Verification Tests"
)

for i in "${!PS1_PHASES[@]}"; do
    pattern="${PS1_PHASES[$i]}"
    label="${PS1_PHASE_LABELS[$i]}"
    if doc_contains_i "${pattern}"; then
        pass "Document covers test.ps1 phase: '${label}'"
    else
        fail "Document must cover test.ps1 phase: '${label}' (no match for pattern: ${pattern})"
    fi
done

# ---------------------------------------------------------------------------
# Section 4: All test.sh phases are documented
# ---------------------------------------------------------------------------
# test.sh phases (Phases 1–9):
#   1. Preflight       — Docker and docker compose availability
#   2. File Existence  — Required project files exist
#   3. Syntax          — bash -n, docker compose config --quiet, nginx -t
#   4. Nginx           — Upstream proxy_pass targets and location routes
#   5. qBittorrent     — Template/config validation (static analysis only)
#   6. Setup           — setup.sh env vars, modes, qBittorrent template deploy
#   7. Configure       — configure.sh/configure.ps1 API function presence
#   8. Container       — Spin up isolated stack; all health checks pass
#   9. Connectivity    — Health endpoints, config.xml creation, get_arr_api_key

section "test.sh Phases: All 9 Phases Documented"

declare -a SH_PHASES=(
    "Phase 1|phase 1"
    "Phase 2|phase 2"
    "Phase 3|phase 3"
    "Phase 4|phase 4"
    "Phase 5|phase 5"
    "Phase 6|phase 6"
    "Phase 7|phase 7"
    "Phase 8|phase 8"
    "Phase 9|phase 9"
)

declare -a SH_PHASE_LABELS=(
    "Phase 1 (Preflight)"
    "Phase 2 (File Existence)"
    "Phase 3 (Syntax)"
    "Phase 4 (Nginx)"
    "Phase 5 (qBittorrent)"
    "Phase 6 (Setup)"
    "Phase 7 (Configure)"
    "Phase 8 (Container Startup)"
    "Phase 9 (Connectivity)"
)

for i in "${!SH_PHASES[@]}"; do
    pattern="${SH_PHASES[$i]}"
    label="${SH_PHASE_LABELS[$i]}"
    if doc_contains_i "${pattern}"; then
        pass "Document documents test.sh ${label}"
    else
        fail "Document must reference test.sh ${label} (no match for pattern: ${pattern})"
    fi
done

# ---------------------------------------------------------------------------
# Section 5: Intentional N/A omissions are explicitly justified
# ---------------------------------------------------------------------------
# The work item calls out two known gaps that have no Bash equivalent:
#   a) PSParser syntax check (PowerShell-only: [System.Management.Automation.PSParser])
#   b) Homepage Tests (no homepage phase in test.sh)
# Each must appear in the document with an explicit justification, not just "N/A".

section "Intentional Omissions: N/A Justifications"

# 5a: PSParser / PSScriptAnalyzer — PowerShell-only syntax check
if doc_contains_i "PSParser|PSScriptAnalyzer"; then
    pass "Document mentions PSParser/PSScriptAnalyzer (PowerShell-only syntax check)"
else
    fail "Document must mention PSParser or PSScriptAnalyzer — the PowerShell syntax check has no Bash equivalent"
fi

# The N/A for PSParser must include a reason (not just the bare label)
if doc_contains_i "PSParser.*[Nn]o.*[Bb]ash|PSParser.*[Nn]/[Aa]|[Nn]/[Aa].*PSParser|PSParser.*[Pp]owerShell.only|PSScriptAnalyzer.*[Nn]/[Aa]|[Nn]/[Aa].*PSScriptAnalyzer"; then
    pass "PSParser N/A entry includes a justification (PowerShell-only)"
else
    fail "PSParser N/A entry must include a justification explaining why there is no Bash equivalent"
fi

# 5b: Homepage Tests — not present in test.sh
if doc_contains_i "[Hh]omepage.*[Nn]/[Aa]|[Hh]omepage.*no.*[Bb]ash|[Hh]omepage.*not.*implemented|[Nn]/[Aa].*[Hh]omepage|[Hh]omepage.*omit|[Hh]omepage.*gap"; then
    pass "Homepage Tests N/A entry is present with context"
else
    fail "Document must note that Homepage Tests (test.ps1) have no Bash equivalent in test.sh"
fi

# ---------------------------------------------------------------------------
# Section 6: Gaps section exists and lists differences
# ---------------------------------------------------------------------------

section "Gaps and Differences Section"

# The document must have an explicit 'gaps' or 'differences' section
if doc_contains_i "^#+.*(gap|Gap|difference|Difference|omission|Omission|missing|Missing)"; then
    pass "Document has a dedicated gaps/differences/omissions section heading"
else
    fail "Document must have a section heading for gaps or intentional omissions (e.g., '## Gaps')"
fi

# The gaps section must reference API Integration Tests as a gap
# (test.ps1 does live API calls; test.sh phase 9 only does basic connectivity)
if doc_contains_i "API Integration.*gap|API Integration.*[Nn]/[Aa]|API Integration.*not.*implement|gap.*API Integration|partial.*API|API.*partial"; then
    pass "Document addresses API Integration Tests gap"
else
    fail "Document must note the gap for API Integration Tests (live API calls in test.ps1 have no full equivalent in test.sh)"
fi

# Configure Script Functionality tests in test.ps1 involve live API calls —
# document must note this gap or mark it as partial coverage
if doc_contains_i "Configure Script Functionality.*gap|Configure Script Functionality.*[Nn]/[Aa]|Configure Script Functionality.*partial|gap.*Configure Script Function"; then
    pass "Document addresses Configure Script Functionality gap"
else
    fail "Document must address the Configure Script Functionality Tests gap (live API calls not replicated in test.sh)"
fi

# ---------------------------------------------------------------------------
# Section 7: Line ranges are referenced
# ---------------------------------------------------------------------------
# The work item requires cross-referencing phase line ranges from the gap
# analysis. The document must include line number references (e.g., "lines 172–200")
# so readers can navigate to the exact test.ps1 / test.sh locations.

section "Line Range References"

# Line references appear as digits with common separators (–, -, to)
if doc_contains "line[s]?[[:space:]]+[0-9]+[[:space:]]*[–\-]|[Ll]ine[s]?[[:space:]]*[0-9]+.*[0-9]+|L[0-9]+[–\-]L[0-9]+"; then
    pass "Document includes line range references (e.g., 'lines 172–200' or 'L172–L200')"
else
    fail "Document must include line range references for each phase so readers can navigate to source"
fi

# ---------------------------------------------------------------------------
# Section 8: Milestone acceptance criteria traceability
# ---------------------------------------------------------------------------
# The work item requires that all milestone acceptance criteria are traceable
# to specific assertions. The document must reference the acceptance criteria
# of the work item and link them to test.sh assertions.

section "Acceptance Criteria Traceability"

# Traceability language — document must connect criteria to assertions
if doc_contains_i "acceptance criteria|traceable|traceab|assertion|verified by"; then
    pass "Document uses traceability language (acceptance criteria / assertions)"
else
    fail "Document must trace acceptance criteria to specific assertions in test.sh"
fi

# The document must reference the -Quick flag correspondence (test.ps1 -Quick
# skips container tests; test.sh has no flag but phases 1-7 serve the same role)
if doc_contains_i "\-Quick|Quick.*flag|phases.*1.*7.*quick|quick.*phases.*1.*7"; then
    pass "Document notes the -Quick flag correspondence (test.ps1 -Quick ↔ test.sh phases 1-7)"
else
    fail "Document must note that test.ps1 -Quick corresponds to running test.sh phases 1-7 only"
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
printf "\n"

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    printf "  %bAll tests passed. Parity document is complete.%b\n\n" "${GREEN}${BOLD}" "${NC}"
    exit 0
else
    printf "  %b%d test(s) failed. Update docs/dev-testing/test-parity.md.%b\n\n" \
        "${RED}${BOLD}" "${FAIL_COUNT}" "${NC}"
    exit 1
fi
