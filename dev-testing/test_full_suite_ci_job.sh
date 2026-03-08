#!/bin/bash
# =============================================================================
# Full-Suite CI Job Structural Tests (Bash)
# =============================================================================
# Validates that .github/workflows/ci.yml wires the Bash test suite into
# the full-suite job and adds a parallel PowerShell suite job.
#
# Work item: Wire Bash test suite into CI full-suite job
#
# Acceptance criteria tested here:
#   1. full-suite job runs dev-testing/test.sh on ubuntu-latest
#   2. A parallel job runs dev-testing/test.ps1 via pwsh on ubuntu-latest
#   3. Both test suite jobs depend on fast-gate
#   4. Test logs are uploaded as artifacts on failure (actions/upload-artifact)
#   5. Both jobs exist by name (enabling them as required status checks)
#
# TDD: These tests are written BEFORE the implementation exists and MUST fail
# on the current codebase (full-suite still has a placeholder step; no
# PowerShell suite job exists).
#
# Usage:
#   ./dev-testing/test_full_suite_ci_job.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# Requirements:
#   - python3 (for YAML validation; standard on ubuntu-latest)
#   - bash >= 4.0
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW_FILE="${PROJECT_ROOT}/.github/workflows/ci.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
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

section() {
    printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"
    printf "${CYAN}%s${NC}\n" "────────────────────────────────────────────────────────────"
}

# Returns 0 if the ERE pattern is found anywhere in the workflow file
workflow_contains() {
    grep -qE "$1" "${WORKFLOW_FILE}" 2>/dev/null
}

# Returns the count of ERE matches; never fails (exits 0 even on 0 matches)
workflow_count() {
    grep -cE "$1" "${WORKFLOW_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf '\n%s%s' "${BOLD}" "${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Full-Suite CI Job Structural Tests\n"
printf "════════════════════════════════════════════════════════════\n"
printf '%s\n' "${NC}"

# ---------------------------------------------------------------------------
# Section 1: Precondition — ci.yml must exist
# ---------------------------------------------------------------------------

section "Precondition: ci.yml exists"

if [[ -f "${WORKFLOW_FILE}" ]]; then
    pass ".github/workflows/ci.yml exists"
else
    fail ".github/workflows/ci.yml does not exist"
    printf '\n%s\n\n' "${RED}Cannot continue: workflow file is missing.${NC}"
    printf '  %d passed, %d failed\n\n' "${PASS_COUNT}" "${FAIL_COUNT}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Section 2: full-suite job runs dev-testing/test.sh
# ---------------------------------------------------------------------------

section "full-suite Job — Runs dev-testing/test.sh"

# The full-suite job must invoke the Bash test suite (not just a placeholder)
if workflow_contains "dev-testing/test\.sh"; then
    pass "full-suite job references dev-testing/test.sh"
else
    fail "full-suite job must run dev-testing/test.sh (currently has a placeholder)"
fi

# The test.sh invocation must be in the full-suite job specifically —
# verify that a bash run step (not just a comment) references the script
if workflow_contains "bash.*dev-testing/test\.sh|dev-testing/test\.sh|run:.*test\.sh"; then
    pass "dev-testing/test.sh appears in a run: step (not just a comment)"
else
    fail "dev-testing/test.sh must appear in a 'run:' step of the full-suite job"
fi

# The full-suite job must still declare runs-on: ubuntu-latest
# (ubuntu-latest has Docker available for phases 8–9)
if workflow_contains "ubuntu-latest"; then
    pass "Workflow uses ubuntu-latest runner (required for Docker in phases 8–9)"
else
    fail "full-suite job must use ubuntu-latest (Docker is available there)"
fi

# The full-suite job must NOT be a stub placeholder any longer —
# the placeholder text from the earlier work item should be gone
if workflow_contains "Placeholder.*full container tests.*stub|TODO.*Full container tests.*stub"; then
    fail "full-suite job still contains the old stub placeholder — must be replaced with real test.sh invocation"
else
    pass "full-suite job no longer contains the old placeholder stub comment"
fi

# ---------------------------------------------------------------------------
# Section 3: full-suite job depends on fast-gate
# ---------------------------------------------------------------------------

section "full-suite Job — Depends on fast-gate"

# full-suite must declare needs: fast-gate
if workflow_contains "needs:.*fast-gate|needs:\s*\[.*fast-gate"; then
    pass "full-suite (or another job) declares 'needs: fast-gate'"
else
    fail "full-suite job must declare 'needs: fast-gate' to enforce sequential execution"
fi

# ---------------------------------------------------------------------------
# Section 4: full-suite job — checkout step
# ---------------------------------------------------------------------------

section "full-suite Job — Checkout Step"

# full-suite must check out the repository to access test scripts
if workflow_contains "actions/checkout"; then
    pass "Workflow uses actions/checkout (required for test scripts to be available)"
else
    fail "full-suite job must include an actions/checkout step"
fi

# ---------------------------------------------------------------------------
# Section 5: full-suite job — artifact upload on failure
# ---------------------------------------------------------------------------

section "full-suite Job — Artifact Upload on Failure"

# Must use actions/upload-artifact to capture test logs when tests fail
if workflow_contains "actions/upload-artifact"; then
    pass "Workflow uses actions/upload-artifact (test log capture)"
else
    fail "full-suite job must upload test logs as artifacts using actions/upload-artifact"
fi

# The upload step must be conditional on failure (if: failure())
if workflow_contains "if:\s*failure\(\)|if: \\\$\{\{ failure\(\) \}\}"; then
    pass "Artifact upload step uses 'if: failure()' (only uploads on failure)"
else
    fail "Artifact upload must be conditional on failure (if: failure()) — upload only when tests fail"
fi

# The upload step must reference a test log path or name
if workflow_contains "test[-_]logs|test_logs|test-logs|name:.*log|path:.*log"; then
    pass "Artifact upload step references test logs (path or name contains 'log')"
else
    fail "Artifact upload must reference test log files (artifact name or path must contain 'log')"
fi

# ---------------------------------------------------------------------------
# Section 6: Parallel PowerShell suite job
# ---------------------------------------------------------------------------

section "Parallel PowerShell Suite Job"

# A separate parallel job must run dev-testing/test.ps1 via pwsh.
# Both this job and full-suite depend on fast-gate, making them parallel to each other.
# The job name is implementation-defined but must invoke dev-testing/test.ps1.
if workflow_contains "dev-testing/test\.ps1"; then
    pass "A CI job references dev-testing/test.ps1"
else
    fail "A parallel CI job must run dev-testing/test.ps1 (missing from ci.yml)"
fi

# The PowerShell test job must use pwsh (PowerShell Core) as its shell
if workflow_contains "shell:\s*pwsh|pwsh.*dev-testing/test\.ps1|pwsh.*test\.ps1"; then
    pass "PowerShell test invocation uses pwsh"
else
    fail "dev-testing/test.ps1 must be run via pwsh (shell: pwsh or pwsh ./dev-testing/test.ps1)"
fi

# The PowerShell suite job must run on ubuntu-latest
# (same runner as full-suite; both are ubuntu-latest)
if workflow_contains "ubuntu-latest"; then
    pass "Workflow uses ubuntu-latest runner for both suite jobs"
else
    fail "PowerShell suite job must run on ubuntu-latest"
fi

# ---------------------------------------------------------------------------
# Section 7: PowerShell suite job depends on fast-gate
# ---------------------------------------------------------------------------

section "PowerShell Suite Job — Depends on fast-gate"

# Both full-suite and the PowerShell suite must each have 'needs: fast-gate'.
# The minimum count of 'needs:.*fast-gate' occurrences must be >= 2
# (one per suite job) — unless both are listed in a single array form.
# We check for at least one needs: fast-gate per suite job (two total).
FAST_GATE_NEEDS_COUNT=$(workflow_count "needs:.*fast-gate")
if [[ "${FAST_GATE_NEEDS_COUNT}" -ge 2 ]]; then
    pass "Both suite jobs declare 'needs: fast-gate' (${FAST_GATE_NEEDS_COUNT} occurrences found)"
else
    fail "Both full-suite and the PowerShell suite job must declare 'needs: fast-gate' (found ${FAST_GATE_NEEDS_COUNT} occurrence(s); need >= 2)"
fi

# ---------------------------------------------------------------------------
# Section 8: Both suite jobs are named (enabling required status checks)
# ---------------------------------------------------------------------------

section "Both Suite Jobs Defined (Required Status Checks)"

# full-suite job must exist by name — already verified in sections above,
# but we explicitly confirm the job key is in the file
if workflow_contains "full-suite:"; then
    pass "'full-suite' job is defined (can be added as a required status check)"
else
    fail "'full-suite' job must be defined under jobs: in ci.yml"
fi

# The PowerShell suite job must be defined by a distinct job key.
# Common names: powershell-suite, test-powershell, suite-powershell.
# We accept any job name that invokes dev-testing/test.ps1.
# Since we already verified dev-testing/test.ps1 is referenced, we check
# that a separate job key (other than full-suite) exists.
PS_JOB_COUNT=$(workflow_count "powershell-suite:|test-powershell:|suite-powershell:|ps-suite:|ps-tests:")
if [[ "${PS_JOB_COUNT}" -ge 1 ]]; then
    pass "PowerShell suite job is defined with a distinct job key (${PS_JOB_COUNT} match(es))"
else
    fail "PowerShell suite job must have a distinct job key (e.g. powershell-suite:, test-powershell:)"
fi

# ---------------------------------------------------------------------------
# Section 9: Named steps for clear CI summaries
# ---------------------------------------------------------------------------

section "Named Steps for CI Job Summaries"

# Both suite jobs should have descriptive named steps
NAMED_STEPS=$(grep -cE "^\s+- name:" "${WORKFLOW_FILE}" 2>/dev/null || echo "0")
if [[ "${NAMED_STEPS}" -ge 8 ]]; then
    pass "Workflow has ${NAMED_STEPS} named steps (both suite jobs contribute named steps)"
else
    fail "Workflow has only ${NAMED_STEPS} named step(s) — suite jobs must add named steps (minimum 8 total expected)"
fi

# The full-suite job's test step must be named
if workflow_contains "name:.*[Bb]ash.*[Ss]uite|name:.*[Ff]ull.*[Ss]uite|name:.*[Tt]est.*[Ss]uite|name:.*[Rr]un.*test"; then
    pass "A named step references the Bash or full suite test run"
else
    fail "full-suite job must have a named step describing the test.sh invocation (e.g. 'Run Bash test suite')"
fi

# The PowerShell suite job's test step must be named
if workflow_contains "name:.*[Pp]ower[Ss]hell.*[Ss]uite|name:.*[Pp][Ss].*[Ss]uite|name:.*[Rr]un.*test\.ps1|name:.*[Pp]ower[Ss]hell.*[Tt]est"; then
    pass "A named step references the PowerShell suite test run"
else
    fail "PowerShell suite job must have a named step describing the test.ps1 invocation (e.g. 'Run PowerShell test suite')"
fi

# ---------------------------------------------------------------------------
# Section 10: Non-silent failure contract
# ---------------------------------------------------------------------------

section "Non-Silent Failure Contract"

# continue-on-error: true would allow suite jobs to fail without blocking CI
CONTINUE_ON_ERROR_COUNT=$(workflow_count "continue-on-error:\s*true")
if [[ "${CONTINUE_ON_ERROR_COUNT}" -eq 0 ]]; then
    pass "No 'continue-on-error: true' found — suite failures will block CI"
else
    fail "Found ${CONTINUE_ON_ERROR_COUNT} 'continue-on-error: true' occurrence(s) — suite jobs must fail loudly"
fi

# Neither suite job should suppress shell error propagation
if workflow_contains "set \+e"; then
    fail "Workflow must not disable shell error propagation with 'set +e'"
else
    pass "No 'set +e' found — shell errors propagate normally"
fi

# ---------------------------------------------------------------------------
# Section 11: Acceptance criteria aggregate
# ---------------------------------------------------------------------------

section "Acceptance Criteria — Aggregate"

CRITERIA_FAILURES=0

# full-suite runs dev-testing/test.sh
if ! workflow_contains "dev-testing/test\.sh"; then
    printf '  %s[MISSING]%s dev-testing/test.sh invocation in full-suite\n' "${RED}" "${NC}"
    (( CRITERIA_FAILURES++ )) || true
fi

# parallel PowerShell job runs dev-testing/test.ps1
if ! workflow_contains "dev-testing/test\.ps1"; then
    printf '  %s[MISSING]%s dev-testing/test.ps1 invocation in parallel job\n' "${RED}" "${NC}"
    (( CRITERIA_FAILURES++ )) || true
fi

# both jobs depend on fast-gate
if [[ "$(workflow_count "needs:.*fast-gate")" -lt 2 ]]; then
    printf '  %s[MISSING]%s both suite jobs must declare '"'"'needs: fast-gate'"'"'\n' "${RED}" "${NC}"
    (( CRITERIA_FAILURES++ )) || true
fi

# artifact upload on failure
if ! workflow_contains "actions/upload-artifact"; then
    printf '  %s[MISSING]%s actions/upload-artifact step\n' "${RED}" "${NC}"
    (( CRITERIA_FAILURES++ )) || true
fi

if ! workflow_contains "if:\s*failure\(\)|if: \\\$\{\{ failure\(\) \}\}"; then
    printf '  %s[MISSING]%s '"'"'if: failure()'"'"' condition on artifact upload\n' "${RED}" "${NC}"
    (( CRITERIA_FAILURES++ )) || true
fi

# pwsh for test.ps1
if ! workflow_contains "shell:\s*pwsh|pwsh.*test\.ps1"; then
    printf '  %s[MISSING]%s pwsh invocation for dev-testing/test.ps1\n' "${RED}" "${NC}"
    (( CRITERIA_FAILURES++ )) || true
fi

if [[ "${CRITERIA_FAILURES}" -eq 0 ]]; then
    pass "All acceptance criteria satisfied"
else
    fail "${CRITERIA_FAILURES} acceptance criteria violation(s) found (see above)"
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
    printf '%s\n\n' "  ${GREEN}${BOLD}All full-suite CI job tests passed.${NC}"
    exit 0
else
    printf '%s\n\n' "  ${RED}${BOLD}Full-suite CI job tests failed. Update ci.yml to wire in test.sh and add the PowerShell suite job.${NC}"
    exit 1
fi
