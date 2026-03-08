#!/bin/bash
# =============================================================================
# ShellCheck Static Analysis Tests
# =============================================================================
# Verifies all Bash scripts in the Simplarr project pass ShellCheck at
# severity=style (the strictest level). Zero warnings is the target.
#
# This is a TDD test file — it MUST fail before the ShellCheck fixes are
# applied, because the scripts currently contain known warnings.
#
# Usage:
#   ./dev-testing/test_shellcheck.sh
#
# Exit Codes:
#   0 - All tests passed (zero ShellCheck warnings)
#   1 - One or more tests failed (warnings found or setup issue)
#
# Requirements:
#   - shellcheck >= 0.9.0
#   Install: sudo apt install shellcheck  (Ubuntu/Debian)
#            brew install shellcheck       (macOS)
#            scoop install shellcheck      (Windows via Scoop)
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

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
    printf '%s%s%s\n' "${CYAN}" "────────────────────────────────────────────────────────────" "${NC}"
}

# ---------------------------------------------------------------------------
# Scripts under test
# ---------------------------------------------------------------------------

declare -a SCRIPTS=(
    "${PROJECT_ROOT}/setup.sh"
    "${PROJECT_ROOT}/configure.sh"
    "${PROJECT_ROOT}/preflight.sh"
    "${PROJECT_ROOT}/utility/check_nas_mounts.sh"
)

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf '\n%s%s' "${BOLD}" "${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  ShellCheck Static Analysis Tests\n"
printf "════════════════════════════════════════════════════════════\n"
printf '%s\n' "${NC}"

# ---------------------------------------------------------------------------
# Test 1: shellcheck must be installed
# ---------------------------------------------------------------------------

section "Environment"

if ! command -v shellcheck &>/dev/null; then
    fail "shellcheck is not installed"
    printf '\n%sERROR: shellcheck not found. Cannot run tests.%s\n' "${RED}" "${NC}"
    printf "Install with:\n"
    printf "  sudo apt install shellcheck   (Ubuntu/Debian)\n"
    printf "  brew install shellcheck       (macOS)\n\n"
    exit 1
fi

pass "shellcheck is installed"

# ---------------------------------------------------------------------------
# Test 2: shellcheck must be >= 0.9.0
# ---------------------------------------------------------------------------

SC_VERSION_RAW=$(shellcheck --version | grep "^version:" | awk '{print $2}')
SC_MAJOR=$(echo "${SC_VERSION_RAW}" | cut -d. -f1)
SC_MINOR=$(echo "${SC_VERSION_RAW}" | cut -d. -f2)

info "shellcheck version: ${SC_VERSION_RAW}"

if [[ "${SC_MAJOR}" -gt 0 ]] || { [[ "${SC_MAJOR}" -eq 0 ]] && [[ "${SC_MINOR}" -ge 9 ]]; }; then
    pass "shellcheck >= 0.9.0"
else
    fail "shellcheck version ${SC_VERSION_RAW} is below the required 0.9.0"
    printf '%s  Upgrade shellcheck and re-run.%s\n' "${YELLOW}" "${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Test 3: All target script files must exist
# ---------------------------------------------------------------------------

section "File Existence"

for script in "${SCRIPTS[@]}"; do
    rel_path="${script#"${PROJECT_ROOT}/"}"
    if [[ -f "${script}" ]]; then
        pass "${rel_path} exists"
    else
        fail "${rel_path} not found (expected at: ${script})"
    fi
done

# Abort early if any file is missing — remaining tests are pointless
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    printf '\n%sCannot continue: required script files are missing.%s\n\n' "${RED}" "${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Test 4: setup.sh — zero ShellCheck warnings at severity=style
# ---------------------------------------------------------------------------

section "ShellCheck: setup.sh"

SETUP_SH="${PROJECT_ROOT}/setup.sh"
printf "  Running: shellcheck --severity=style %s\n" "setup.sh"

if shellcheck --severity=style "${SETUP_SH}"; then
    pass "setup.sh — zero ShellCheck warnings"
else
    fail "setup.sh — ShellCheck reported warnings (see output above)"
fi

# ---------------------------------------------------------------------------
# Test 5: configure.sh — zero ShellCheck warnings at severity=style
# ---------------------------------------------------------------------------

section "ShellCheck: configure.sh"

CONFIGURE_SH="${PROJECT_ROOT}/configure.sh"
printf "  Running: shellcheck --severity=style %s\n" "configure.sh"

if shellcheck --severity=style "${CONFIGURE_SH}"; then
    pass "configure.sh — zero ShellCheck warnings"
else
    fail "configure.sh — ShellCheck reported warnings (see output above)"
fi

# ---------------------------------------------------------------------------
# Test 6: preflight.sh — zero ShellCheck warnings at severity=style
# ---------------------------------------------------------------------------

section "ShellCheck: preflight.sh"

PREFLIGHT_SH="${PROJECT_ROOT}/preflight.sh"
printf "  Running: shellcheck --severity=style %s\n" "preflight.sh"

if shellcheck --severity=style "${PREFLIGHT_SH}"; then
    pass "preflight.sh — zero ShellCheck warnings"
else
    fail "preflight.sh — ShellCheck reported warnings (see output above)"
fi

# ---------------------------------------------------------------------------
# Test 7: utility/check_nas_mounts.sh — zero ShellCheck warnings
# ---------------------------------------------------------------------------

section "ShellCheck: utility/check_nas_mounts.sh"

CHECK_NAS_SH="${PROJECT_ROOT}/utility/check_nas_mounts.sh"
printf "  Running: shellcheck --severity=style %s\n" "utility/check_nas_mounts.sh"

if shellcheck --severity=style "${CHECK_NAS_SH}"; then
    pass "utility/check_nas_mounts.sh — zero ShellCheck warnings"
else
    fail "utility/check_nas_mounts.sh — ShellCheck reported warnings (see output above)"
fi

# ---------------------------------------------------------------------------
# Test 8: No undocumented inline shellcheck disable directives
# ---------------------------------------------------------------------------
# Acceptance criteria: any intentional suppression must include a comment
# explaining WHY. This test catches bare directives that lack justification.
#
# A documented disable looks like:
#   # shellcheck disable=SC2034  # reason: variable used by sourced scripts
# An undocumented disable looks like (bare directive, no trailing comment):
#   # shellcheck disable=SC2034

section "Documentation: shellcheck disable directives"

BARE_DISABLE_FOUND=false

for script in "${SCRIPTS[@]}"; do
    rel_path="${script#"${PROJECT_ROOT}/"}"

    # Match lines that are a shellcheck disable directive WITHOUT a following
    # explanation comment. Pattern: '# shellcheck disable=...' with nothing
    # after the directive code(s) except optional whitespace.
    # A documented one has additional text (the reason) after the code(s).
    while IFS= read -r line_info; do
        lineno=$(echo "${line_info}" | cut -d: -f1)
        content=$(echo "${line_info}" | cut -d: -f2-)
        printf '  %s[WARN]%s Undocumented disable at %s:%s\n' "${YELLOW}" "${NC}" "${rel_path}" "${lineno}"
        printf "         %s\n" "${content}"
        printf "         Add a comment after the directive explaining why it is suppressed.\n"
        BARE_DISABLE_FOUND=true
    done < <(
        grep -n "# shellcheck disable=" "${script}" 2>/dev/null \
        | grep -v "# shellcheck disable=SC[0-9]*[[:space:]]*#" || true
    )
done

if [[ "${BARE_DISABLE_FOUND}" == "false" ]]; then
    pass "No undocumented shellcheck disable directives found"
else
    fail "Undocumented shellcheck disable directive(s) found — add a reason comment"
fi

# ---------------------------------------------------------------------------
# Test 9: All scripts use #!/bin/bash (not #!/bin/sh)
# ---------------------------------------------------------------------------
# configure.sh uses bash-specific features (local, [[ ]], etc.).
# Ensure the shebang matches the actual shell dialect used.

section "Shebang Lines"

for script in "${SCRIPTS[@]}"; do
    rel_path="${script#"${PROJECT_ROOT}/"}"
    first_line=$(head -n 1 "${script}")
    if [[ "${first_line}" == "#!/bin/bash" ]]; then
        pass "${rel_path} — shebang is #!/bin/bash"
    else
        fail "${rel_path} — unexpected shebang: '${first_line}' (expected #!/bin/bash)"
    fi
done

# ---------------------------------------------------------------------------
# Test 10: shellcheck exits 0 when run on all scripts together
# ---------------------------------------------------------------------------
# Belt-and-suspenders: run shellcheck once across all files to catch any
# cross-file issues (e.g., SC1090 source issues) that may only surface
# when run together.

section "ShellCheck: all scripts (combined run)"

printf "  Running: shellcheck --severity=style <all scripts>\n"

if shellcheck --severity=style "${SCRIPTS[@]}"; then
    pass "All scripts pass combined ShellCheck run"
else
    fail "Combined ShellCheck run found warnings (see output above)"
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
    printf '  %s%sAll tests passed. Scripts are ShellCheck clean.%s\n\n' "${GREEN}" "${BOLD}" "${NC}"
    exit 0
else
    printf '  %s%sTests failed. Fix ShellCheck warnings before merging.%s\n\n' "${RED}" "${BOLD}" "${NC}"
    printf "  Common fixes:\n"
    printf "    SC2162: Add -r flag to read:  read -r var\n"
    printf "    SC2155: Separate local and assignment:\n"
    printf "              local var\n"
    printf "              var=\$(command)\n"
    printf "    SC2164: Use cd with error guard: cd dir || exit 1\n"
    printf "    SC2086: Double-quote variable expansions: \"\$var\"\n"
    printf "\n"
    exit 1
fi
