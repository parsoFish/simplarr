#!/bin/bash
# =============================================================================
# README CI Badge and Development Section Tests (Bash)
# =============================================================================
# Validates that README.md contains a CI status badge using the correct GitHub
# Actions badge URL format, positioned before the Early Release Notice callout,
# and that a Development section references the test suite and CI requirement.
#
# Work item: Add CI status badge to README
#
# Acceptance criteria tested here:
#   1. README.md contains a CI badge with the correct GitHub Actions badge URL format
#   2. Badge is positioned before the Early Release Notice callout
#   3. Badge links to the CI workflow page (Actions workflow URL)
#   4. A Development section references dev-testing/test.ps1
#   5. The Development section mentions CI must pass before merging
#
# TDD: These tests are written BEFORE the implementation exists and MUST fail
# on the current codebase until README.md is updated.
#
# Usage:
#   ./dev-testing/test_readme_badge.sh
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
README_FILE="${PROJECT_ROOT}/readme.md"

# GitHub repo details — must match the actual repository
REPO_OWNER="parsoFish"
REPO_NAME="simplarr"
WORKFLOW_FILE="ci.yml"
BADGE_URL_PATTERN="https://github\.com/${REPO_OWNER}/${REPO_NAME}/actions/workflows/${WORKFLOW_FILE}/badge\.svg"
WORKFLOW_URL_PATTERN="https://github\.com/${REPO_OWNER}/${REPO_NAME}/actions/workflows/${WORKFLOW_FILE}"
EARLY_RELEASE_PATTERN="Early Release Notice"

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
    printf "  ${GREEN}[PASS]${NC} %s\n" "$1"
    (( PASS_COUNT++ )) || true
}

fail() {
    printf "  ${RED}[FAIL]${NC} %s\n" "$1"
    (( FAIL_COUNT++ )) || true
}

info() {
    printf "  ${BLUE}[INFO]${NC} %s\n" "$1"
}

section() {
    printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"
    printf "${CYAN}%s${NC}\n" "────────────────────────────────────────────────────────────"
}

# Returns 0 if pattern is found in README
readme_contains() {
    grep -qE "$1" "${README_FILE}" 2>/dev/null
}

# Returns the line number of the first match, or 0 if not found
readme_line_of() {
    grep -nE "$1" "${README_FILE}" 2>/dev/null | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf "\n${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  README CI Badge and Development Section Tests\n"
printf "════════════════════════════════════════════════════════════\n"
printf "${NC}\n"

# ---------------------------------------------------------------------------
# Section 1: README exists
# ---------------------------------------------------------------------------

section "File Existence"

if [[ -f "${README_FILE}" ]]; then
    pass "readme.md exists at project root"
else
    fail "readme.md does not exist"
    printf "\n${RED}Cannot continue: README file is missing.${NC}\n\n"
    printf "  ${PASS_COUNT} passed, ${FAIL_COUNT} failed\n\n"
    exit 1
fi

# ---------------------------------------------------------------------------
# Section 2: CI badge presence
# ---------------------------------------------------------------------------

section "CI Badge Presence"

# Badge image URL must use the standard GitHub Actions badge format
if readme_contains "${BADGE_URL_PATTERN}"; then
    pass "README contains GitHub Actions badge image URL (${BADGE_URL_PATTERN})"
else
    fail "README must contain a CI badge using the GitHub Actions badge URL format: https://github.com/${REPO_OWNER}/${REPO_NAME}/actions/workflows/${WORKFLOW_FILE}/badge.svg"
fi

# Badge must be in markdown image syntax: ![...](URL)
if readme_contains "!\[.*\]\(${BADGE_URL_PATTERN}\)"; then
    pass "CI badge uses correct markdown image syntax: ![...](badge_url)"
else
    fail "CI badge must use markdown image syntax: ![CI](https://github.com/${REPO_OWNER}/${REPO_NAME}/actions/workflows/${WORKFLOW_FILE}/badge.svg)"
fi

# ---------------------------------------------------------------------------
# Section 3: Badge link (badge must be clickable and link to workflow page)
# ---------------------------------------------------------------------------

section "CI Badge Link"

# Badge must be wrapped in a markdown link pointing to the workflow page
if readme_contains "\[!\[.*\]\(${BADGE_URL_PATTERN}\)\]\(${WORKFLOW_URL_PATTERN}\)"; then
    pass "CI badge is wrapped in a link to the Actions workflow page"
else
    fail "CI badge must be wrapped in a markdown link to ${WORKFLOW_URL_PATTERN}"
fi

# The workflow URL link must reference the correct workflow file name
if readme_contains "${WORKFLOW_FILE}"; then
    pass "Badge references the ci.yml workflow file"
else
    fail "Badge must reference the ci.yml workflow file"
fi

# ---------------------------------------------------------------------------
# Section 4: Badge position (before Early Release Notice)
# ---------------------------------------------------------------------------

section "Badge Position"

# Determine line numbers to verify ordering
BADGE_LINE=$(readme_line_of "${BADGE_URL_PATTERN}")
EARLY_RELEASE_LINE=$(readme_line_of "${EARLY_RELEASE_PATTERN}")

info "Badge line: ${BADGE_LINE:-not found}"
info "Early Release Notice line: ${EARLY_RELEASE_LINE:-not found}"

if [[ -z "${BADGE_LINE}" || "${BADGE_LINE}" -eq 0 ]]; then
    fail "CI badge not found in README — cannot verify position"
elif [[ -z "${EARLY_RELEASE_LINE}" || "${EARLY_RELEASE_LINE}" -eq 0 ]]; then
    fail "'Early Release Notice' callout not found in README — cannot verify badge position"
elif [[ "${BADGE_LINE}" -lt "${EARLY_RELEASE_LINE}" ]]; then
    pass "CI badge (line ${BADGE_LINE}) appears before Early Release Notice (line ${EARLY_RELEASE_LINE})"
else
    fail "CI badge (line ${BADGE_LINE}) must appear BEFORE the Early Release Notice callout (line ${EARLY_RELEASE_LINE})"
fi

# Badge must be near the top of the document (within the header section, first ~15 lines)
if [[ -n "${BADGE_LINE}" && "${BADGE_LINE}" -gt 0 && "${BADGE_LINE}" -le 15 ]]; then
    pass "CI badge is in the header section (line ${BADGE_LINE} <= 15)"
else
    fail "CI badge must appear in the header section (within the first 15 lines), currently at line ${BADGE_LINE:-not found}"
fi

# ---------------------------------------------------------------------------
# Section 5: Development section content
# ---------------------------------------------------------------------------

section "Development Section"

# A Development section must exist (case-insensitive match for common headings)
if readme_contains "^#+\s+(Development|Contributing|Development & Testing)"; then
    pass "README contains a Development section heading"
else
    fail "README must contain a 'Development' section heading (e.g., ## Development)"
fi

# The section must reference the test script path: dev-testing/test.ps1
if readme_contains "dev-testing/test\.ps1"; then
    pass "Development section references dev-testing/test.ps1"
else
    fail "Development section must reference 'dev-testing/test.ps1' so contributors know how to run tests"
fi

# The section must mention CI requirement before merging
if readme_contains "[Cc][Ii].*[Pp]ass|[Pp]ass.*[Cc][Ii]|[Cc][Ii].*must|must.*[Cc][Ii]|[Cc][Ii].*before.*merge|merge.*[Cc][Ii]|[Cc][Ii].*required"; then
    pass "Development section mentions CI must pass before merging"
else
    fail "Development section must state that CI must pass before merging (e.g., 'CI must pass before merging')"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf "\n${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Summary\n"
printf "════════════════════════════════════════════════════════════\n"
printf "${NC}\n"

printf "  ${GREEN}Passed:${NC} %d\n" "${PASS_COUNT}"
printf "  ${RED}Failed:${NC} %d\n" "${FAIL_COUNT}"
printf "\n"

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    printf "  ${GREEN}${BOLD}All README badge tests passed.${NC}\n\n"
    exit 0
else
    printf "  ${RED}${BOLD}README badge tests failed. Update readme.md with the required badge and Development section.${NC}\n\n"
    exit 1
fi
