#!/bin/bash
# =============================================================================
# dev-testing/README.md Content Tests (Bash)
# =============================================================================
# Validates that dev-testing/README.md documents the Bash test suite (test.sh)
# alongside test.ps1. Verifies every required section from the work item:
#
#   - test.sh usage, flags, and prerequisites (Docker, bash 4+, ShellCheck)
#   - -Quick equivalent (phases 1-7 only) is documented
#   - Port isolation strategy for phases 8-9 is explained
#   - Cleanup mechanism is documented
#   - Pass/fail/skip output interpretation is explained
#   - Phase correspondence table (test.ps1 <-> test.sh) is present
#   - Contributor workflow requires BOTH test suites to pass before PR
#
# TDD: These tests are written BEFORE the README is updated and MUST fail
# on the current codebase until dev-testing/README.md is updated.
#
# Usage:
#   ./dev-testing/test_dev_testing_readme.sh
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
README_FILE="${SCRIPT_DIR}/README.md"

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

# Returns 0 if extended regex pattern is found in README (case-sensitive)
readme_contains() {
    grep -qE "$1" "${README_FILE}" 2>/dev/null
}

# Returns 0 if extended regex pattern is found in README (case-insensitive)
readme_contains_i() {
    grep -qiE "$1" "${README_FILE}" 2>/dev/null
}

# Returns the line number of the first match, or empty string if not found
readme_line_of() {
    grep -nE "$1" "${README_FILE}" 2>/dev/null | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  dev-testing/README.md Documentation Tests\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

# ---------------------------------------------------------------------------
# Section 1: File existence
# ---------------------------------------------------------------------------

section "File Existence"

if [[ -f "${README_FILE}" ]]; then
    pass "dev-testing/README.md exists"
else
    fail "dev-testing/README.md does not exist"
    printf "\n%bCannot continue: README file is missing.%b\n\n" "${RED}" "${NC}"
    printf "  %d passed, %d failed\n\n" "${PASS_COUNT}" "${FAIL_COUNT}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Section 2: test.sh is documented
# ---------------------------------------------------------------------------

section "test.sh Documentation"

# test.sh must appear in the README as a documented script (not just a mention
# inside test.ps1 text). It should have its own heading or named entry.
if readme_contains "test\.sh"; then
    pass "README references test.sh"
else
    fail "README must document test.sh — no mention of 'test.sh' found"
fi

# A dedicated heading or subsection for test.sh must exist so readers can
# navigate directly to Bash-specific docs without reading through test.ps1 docs.
if readme_contains "^#+.*test\.sh|test\.sh.*\(Bash\)|### test\.sh|## test\.sh"; then
    pass "README has a dedicated section/heading for test.sh"
else
    fail "README must have a dedicated heading for test.sh (e.g., '### test.sh (Bash)')"
fi

# ---------------------------------------------------------------------------
# Section 3: Prerequisites for test.sh
# ---------------------------------------------------------------------------

section "test.sh Prerequisites"

# Docker is required for phases 3 (nginx -t) and 8-9 (container startup)
if readme_contains_i "docker" && readme_contains "test\.sh"; then
    pass "README mentions Docker as a prerequisite for test.sh"
else
    fail "README must list Docker as a prerequisite for test.sh"
fi

# bash 4+ is required (test.sh uses declare -a, (( )) arithmetic, [[ ]], etc.)
if readme_contains "[Bb]ash.*4|bash.*>=.*4|bash 4\+"; then
    pass "README specifies bash >= 4 as a prerequisite"
else
    fail "README must specify bash 4+ as a prerequisite for test.sh"
fi

# ShellCheck is optional but the README should mention it as a linting tool
if readme_contains_i "shellcheck"; then
    pass "README mentions ShellCheck (linting tool prerequisite)"
else
    fail "README must mention ShellCheck as a tool for linting test.sh"
fi

# ---------------------------------------------------------------------------
# Section 4: How to run test.sh
# ---------------------------------------------------------------------------

section "Running test.sh"

# The README must show the command to run the full test suite
if readme_contains "\./dev-testing/test\.sh|bash.*dev-testing/test\.sh|dev-testing/test\.sh"; then
    pass "README shows how to run test.sh (usage command is present)"
else
    fail "README must show how to run test.sh (e.g., './dev-testing/test.sh')"
fi

# ---------------------------------------------------------------------------
# Section 5: Phases 1-7 only (-Quick equivalent)
# ---------------------------------------------------------------------------

section "Phases 1-7 Quick Mode Equivalent"

# The -Quick flag for test.ps1 skips container startup (phases 4+). test.sh
# doesn't have a -Quick flag, but the README must document what to do for
# a quick check — either via an env var, a note, or a separate invocation.
# Accept any mention that clarifies phases 1-7 are the non-container checks.
if readme_contains "[Pp]hase.*[17]|1.7|phases 1.*7|quick.*phase|phase.*quick"; then
    pass "README explains the phases 1-7 (non-container / quick) scope"
else
    fail "README must document which phases (1-7) correspond to quick/syntax checks, as the -Quick equivalent"
fi

# The -Quick flag itself must be referenced in context of test.ps1 so readers
# understand the correspondence between the two runners.
if readme_contains "\-Quick|-quick|Quick.*flag|quick.*flag"; then
    pass "README mentions the -Quick flag (test.ps1) for comparison"
else
    fail "README must reference the -Quick flag of test.ps1 when explaining the phases 1-7 equivalent"
fi

# ---------------------------------------------------------------------------
# Section 6: Port isolation strategy (phases 8-9)
# ---------------------------------------------------------------------------

section "Port Isolation Strategy"

# Phases 8-9 use random base ports to avoid clashing with production services.
# The README must explain WHY this is needed (concurrent runs, production conflict).
if readme_contains "port.*isolat|isolat.*port|random.*port|port.*random"; then
    pass "README explains the port isolation strategy"
else
    fail "README must document the port isolation strategy used in phases 8-9"
fi

# The env var SIMPLARR_TEST_BASE_PORT should be documented so CI / power users
# can override it when they need deterministic port assignments.
if readme_contains "SIMPLARR_TEST_BASE_PORT"; then
    pass "README documents SIMPLARR_TEST_BASE_PORT environment variable"
else
    fail "README must document the SIMPLARR_TEST_BASE_PORT env var used for port override"
fi

# The port range used (20000-29999) or the random mechanism should be explained
if readme_contains "20[0-9]{3}|random.*base.*port|base.*port.*random|port.*range"; then
    pass "README explains the port range / randomisation mechanism"
else
    fail "README must explain the port range (e.g., 20000-29999) or randomisation mechanism for test ports"
fi

# ---------------------------------------------------------------------------
# Section 7: Cleanup mechanism
# ---------------------------------------------------------------------------

section "Cleanup Mechanism"

# test.sh uses an EXIT trap to always remove containers/volumes on exit.
# The README must document that cleanup is automatic via the EXIT trap.
if readme_contains "EXIT.*trap|trap.*EXIT|automatic.*clean|clean.*automatic"; then
    pass "README documents the automatic EXIT trap cleanup"
else
    fail "README must document the automatic cleanup via EXIT trap (containers and volumes removed on exit)"
fi

# The README must also mention that no -Cleanup flag is needed (unlike test.ps1),
# or at minimum explain the automatic teardown behaviour.
if readme_contains "auto.*clean|clean.*auto|automatic|always.*clean|clean.*always"; then
    pass "README explains containers are cleaned up automatically"
else
    fail "README must explain that test.sh cleans up containers/volumes automatically on exit"
fi

# Docker compose down --volumes must be mentioned so readers understand data is removed
if readme_contains "down.*--volumes|--volumes.*down|volumes.*removed|removed.*volumes"; then
    pass "README mentions 'docker compose down --volumes' for cleanup"
else
    fail "README must mention 'down --volumes' to clarify that volumes are removed during cleanup"
fi

# ---------------------------------------------------------------------------
# Section 8: Output interpretation (pass/fail/skip)
# ---------------------------------------------------------------------------

section "Output Interpretation"

# Readers need to know how to interpret the three output states
if readme_contains "\[PASS\]|\[FAIL\]|\[SKIP\]|PASS.*FAIL.*SKIP|pass.*fail.*skip"; then
    pass "README documents [PASS], [FAIL], [SKIP] output indicators"
else
    fail "README must explain the [PASS], [FAIL], [SKIP] output indicators"
fi

# Exit code meaning must be documented (0 = all passed, 1 = failures)
if readme_contains "[Ee]xit.*code|exit code.*0|exit.*1|returns.*0|returns.*1"; then
    pass "README documents exit codes (0 = pass, 1 = fail)"
else
    fail "README must document exit codes (0 = all tests passed, 1 = one or more failures)"
fi

# ---------------------------------------------------------------------------
# Section 9: Phase correspondence table
# ---------------------------------------------------------------------------

section "Phase Correspondence Table"

# A table must exist showing which test.ps1 phases map to which test.sh phases.
# Accept a markdown table, definition list, or structured list.
if readme_contains "\|.*test\.ps1.*\|.*test\.sh.*\||Phase.*test\.ps1.*test\.sh|test\.ps1.*Phase.*test\.sh"; then
    pass "README contains a phase correspondence table between test.ps1 and test.sh"
else
    fail "README must contain a phase correspondence table mapping test.ps1 phases to test.sh phases"
fi

# The table must cover both suites — at minimum Phases 1 and 8 must appear
# (1 = preflight, present in both; 8 = container startup, present in test.sh)
PHASE1_LINE=$(readme_line_of "Phase 1|phase 1")
PHASE8_LINE=$(readme_line_of "Phase 8|phase 8")
TABLE_LINE=$(readme_line_of "\|.*test\.ps1.*\|.*test\.sh.*\|")

info "Phase 1 line: ${PHASE1_LINE:-not found}"
info "Phase 8 line: ${PHASE8_LINE:-not found}"
info "Table header line: ${TABLE_LINE:-not found}"

if [[ -n "${PHASE1_LINE}" && -n "${PHASE8_LINE}" && -n "${TABLE_LINE}" ]]; then
    pass "Correspondence table covers Phase 1 and Phase 8 (full range)"
else
    fail "Phase correspondence table must list phases 1 through at least 8 from both test.ps1 and test.sh"
fi

# ---------------------------------------------------------------------------
# Section 10: Contributor workflow — both suites required
# ---------------------------------------------------------------------------

section "Contributor Workflow"

# The contributor workflow / PR checklist must mention test.sh — not just test.ps1
if readme_contains "test\.sh.*PR|PR.*test\.sh|test\.sh.*pull request|pull request.*test\.sh|test\.sh.*before.*PR|before.*PR.*test\.sh"; then
    pass "Contributor workflow explicitly mentions test.sh before opening a PR"
else
    # Fallback: acceptable if the section contains "both" suites language near PR context
    if readme_contains "both.*suite|suite.*both|test\.ps1.*test\.sh.*PR|test\.sh.*test\.ps1.*PR"; then
        pass "Contributor workflow references both test suites in PR context"
    else
        fail "Contributor workflow must require test.sh to pass before opening a PR (not just test.ps1)"
    fi
fi

# The workflow section must reference test.ps1 as well (to keep both documented)
if readme_contains "test\.ps1.*PR|PR.*test\.ps1|test\.ps1.*pull request|pull request.*test\.ps1|test\.ps1.*before"; then
    pass "Contributor workflow also references test.ps1 (both suites covered)"
else
    fail "Contributor workflow must reference both test.sh AND test.ps1 before opening a PR"
fi

# A contributor workflow heading must exist to provide structure
if readme_contains "^#+.*(Contributor|Contributing|Workflow|Before.*PR|PR.*Checklist)"; then
    pass "README has a contributor workflow section heading"
else
    fail "README must have a contributor workflow section (e.g., '## Contributor Workflow' or '## Contributing')"
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
    printf "  %bAll README documentation tests passed.%b\n\n" "${GREEN}${BOLD}" "${NC}"
    exit 0
else
    printf "  %b%d test(s) failed. Update dev-testing/README.md with the required documentation.%b\n\n" \
        "${RED}${BOLD}" "${FAIL_COUNT}" "${NC}"
    exit 1
fi
