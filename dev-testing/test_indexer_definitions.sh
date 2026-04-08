#!/bin/bash
# =============================================================================
# Simplarr — Prowlarr $IndexerDefinitions Data Structure Validation (TDD)
# =============================================================================
# Validates that the Prowlarr indexer list is extracted from an inline local
# variable ($indexers inside Add-ProwlarrPublicIndexer) to a script-level
# $IndexerDefinitions array in configure.ps1.
#
# Test Phases:
#   1  Array Presence        — $IndexerDefinitions must be defined at script scope
#   2  Array Structure       — must not appear inside any function body
#   3  Entry Count           — exactly 5 indexers in the array
#   4  Entry Schema          — each entry has Name, Url/BaseUrl, Definition keys
#   5  Expected Indexers     — all 5 known indexers with correct URLs
#   6  Function Loop         — Add-ProwlarrPublicIndexer references $IndexerDefinitions
#   7  Local Var Removed     — Add-ProwlarrPublicIndexer no longer has local $indexers
#   8  Syntax Regression     — configure.ps1 remains syntactically valid bash-readable
#
# TDD: Phases 1–7 FAIL before implementation (local $indexers still exists;
#      $IndexerDefinitions is not defined). Phase 8 is a regression guard.
#
# Usage:
#   ./dev-testing/test_indexer_definitions.sh
#
# Exit Codes:
#   0 — All tests passed
#   1 — One or more tests failed
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURE_PS1="${PROJECT_ROOT}/configure.ps1"

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

section() {
    printf "\n%b%s%b\n" "${BOLD}${CYAN}" "$1" "${NC}"
    printf "%b%s%b\n" "${CYAN}" "────────────────────────────────────────────────────────────" "${NC}"
}

# Extract lines belonging to a named PowerShell function (function FuncName ... closing })
extract_ps_function_body() {
    local func_name="$1"
    local file="$2"
    sed -n "/^function ${func_name}/,/^}/p" "${file}"
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Prowlarr \$IndexerDefinitions Data Structure Validation (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

if [[ ! -f "${CONFIGURE_PS1}" ]]; then
    printf "%b[FATAL]%b configure.ps1 not found at %s\n" "${RED}" "${NC}" "${CONFIGURE_PS1}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1: $IndexerDefinitions variable presence
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 1: \$IndexerDefinitions Variable Presence (TDD — fails before implementation)"

if grep -qP '^\$IndexerDefinitions\s*=' "${CONFIGURE_PS1}"; then
    pass "\$IndexerDefinitions is defined at the top level of configure.ps1"
else
    fail "\$IndexerDefinitions is not defined at the top level — it must be promoted from the local \$indexers variable inside Add-ProwlarrPublicIndexer"
fi

# ---------------------------------------------------------------------------
# Phase 2: $IndexerDefinitions must NOT be inside a function body
# ---------------------------------------------------------------------------

section "Phase 2: \$IndexerDefinitions Defined Outside Functions"

FUNC_BODY_LINES="$(grep -n 'IndexerDefinitions' "${CONFIGURE_PS1}" || true)"
INDEXER_DEF_LINE="$(grep -n '^\$IndexerDefinitions' "${CONFIGURE_PS1}" | head -1 | cut -d: -f1 || true)"

if [[ -z "${INDEXER_DEF_LINE}" ]]; then
    skip "\$IndexerDefinitions not yet defined — skipping scope check"
else
    # Check that the line is not inside a function: look for a 'function ' line
    # before INDEXER_DEF_LINE that is NOT yet closed
    LINES_BEFORE="$(head -n "${INDEXER_DEF_LINE}" "${CONFIGURE_PS1}")"
    FUNCTION_OPENS="$(echo "${LINES_BEFORE}" | grep -c '^function ' || true)"
    # Count closing braces at col 0 (function ends)
    FUNCTION_CLOSES="$(echo "${LINES_BEFORE}" | grep -c '^}' || true)"

    if (( FUNCTION_OPENS <= FUNCTION_CLOSES )); then
        pass "\$IndexerDefinitions is defined at script scope (not inside a function body)"
    else
        fail "\$IndexerDefinitions appears to be defined inside a function body — it must be a script-level constant"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: Entry count — exactly 5 indexers
# ---------------------------------------------------------------------------

section "Phase 3: Entry Count (exactly 5 indexers)"

# Count Name = occurrences within the $IndexerDefinitions block
INDEXER_DEF_LINE="$(grep -n '^\$IndexerDefinitions' "${CONFIGURE_PS1}" | head -1 | cut -d: -f1 || true)"

if [[ -z "${INDEXER_DEF_LINE}" ]]; then
    skip "Cannot check entry count — \$IndexerDefinitions not defined yet"
else
    # Extract from $IndexerDefinitions = @( to the matching closing )
    ARRAY_BLOCK="$(awk "NR>=${INDEXER_DEF_LINE}" "${CONFIGURE_PS1}" | awk '/^\$IndexerDefinitions/,/^\)/' | head -40)"
    NAME_COUNT="$(echo "${ARRAY_BLOCK}" | grep -c 'Name\s*=' || true)"

    if [[ "${NAME_COUNT}" -eq 5 ]]; then
        pass "\$IndexerDefinitions contains exactly 5 indexer entries (Name count = ${NAME_COUNT})"
    else
        fail "\$IndexerDefinitions must contain exactly 5 indexers; found ${NAME_COUNT} Name keys in the array block"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 4: Entry schema — each entry has required fields
# ---------------------------------------------------------------------------

section "Phase 4: Entry Schema (Name, Url/BaseUrl, Definition keys)"

INDEXER_DEF_LINE="$(grep -n '^\$IndexerDefinitions' "${CONFIGURE_PS1}" | head -1 | cut -d: -f1 || true)"

if [[ -z "${INDEXER_DEF_LINE}" ]]; then
    skip "Cannot check entry schema — \$IndexerDefinitions not defined yet"
else
    ARRAY_BLOCK="$(awk "NR>=${INDEXER_DEF_LINE}" "${CONFIGURE_PS1}" | awk '/^\$IndexerDefinitions/,/^\)/' | head -40)"

    if echo "${ARRAY_BLOCK}" | grep -qE 'Name\s*='; then
        pass "Array entries include a 'Name' key"
    else
        fail "Array entries are missing the 'Name' key"
    fi

    if echo "${ARRAY_BLOCK}" | grep -qE '(Url|BaseUrl)\s*='; then
        pass "Array entries include a 'Url' or 'BaseUrl' key"
    else
        fail "Array entries are missing a 'Url' or 'BaseUrl' key — needed by Add-ProwlarrIndexer -BaseUrl"
    fi

    if echo "${ARRAY_BLOCK}" | grep -qE '(Definition|DefinitionName)\s*='; then
        pass "Array entries include a 'Definition' or 'DefinitionName' key"
    else
        fail "Array entries are missing a 'Definition' or 'DefinitionName' key — needed by Add-ProwlarrIndexer -DefinitionName"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 5: All expected indexers present with correct values
# ---------------------------------------------------------------------------

section "Phase 5: Expected Indexers Present (name, URL, definition name)"

declare -A INDEXER_URLS=(
    ["YTS"]="yts.mx"
    ["The Pirate Bay"]="thepiratebay.org"
    ["TorrentGalaxy"]="torrentgalaxy.to"
    ["Nyaa.si"]="nyaa.si"
    ["LimeTorrents"]="limetorrents.lol"
)

declare -A INDEXER_DEFS=(
    ["YTS"]="yts"
    ["The Pirate Bay"]="thepiratebay"
    ["TorrentGalaxy"]="torrentgalaxy"
    ["Nyaa.si"]="nyaasi"
    ["LimeTorrents"]="limetorrents"
)

for indexer_name in "YTS" "The Pirate Bay" "TorrentGalaxy" "Nyaa.si" "LimeTorrents"; do
    expected_url="${INDEXER_URLS[$indexer_name]}"
    expected_def="${INDEXER_DEFS[$indexer_name]}"

    if grep -q "${expected_url}" "${CONFIGURE_PS1}"; then
        pass "URL for '${indexer_name}' (${expected_url}) is present in configure.ps1"
    else
        fail "URL for '${indexer_name}' (${expected_url}) is missing — must not be dropped during refactor"
    fi

    if grep -q "\"${expected_def}\"" "${CONFIGURE_PS1}"; then
        pass "Definition name '${expected_def}' for '${indexer_name}' is present in configure.ps1"
    else
        fail "Definition name '${expected_def}' for '${indexer_name}' is missing — Prowlarr Cardigann needs this exact identifier"
    fi
done

# ---------------------------------------------------------------------------
# Phase 6: Add-ProwlarrPublicIndexer references $IndexerDefinitions
# ---------------------------------------------------------------------------

section "Phase 6: Add-ProwlarrPublicIndexer Uses \$IndexerDefinitions"

FUNC_BODY="$(extract_ps_function_body "Add-ProwlarrPublicIndexer" "${CONFIGURE_PS1}")"

if [[ -z "${FUNC_BODY}" ]]; then
    fail "Add-ProwlarrPublicIndexer function not found in configure.ps1"
else
    if echo "${FUNC_BODY}" | grep -q 'IndexerDefinitions'; then
        pass "Add-ProwlarrPublicIndexer references \$IndexerDefinitions in its body"
    else
        fail "Add-ProwlarrPublicIndexer does not reference \$IndexerDefinitions — it must loop over the script-level array"
    fi

    if echo "${FUNC_BODY}" | grep -q 'foreach'; then
        pass "Add-ProwlarrPublicIndexer contains a foreach loop"
    else
        fail "Add-ProwlarrPublicIndexer has no foreach loop — a loop over \$IndexerDefinitions is required"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 7: Local $indexers variable removed from Add-ProwlarrPublicIndexer
# ---------------------------------------------------------------------------

section "Phase 7: Local \$indexers Variable Removed (TDD — fails before implementation)"

FUNC_BODY="$(extract_ps_function_body "Add-ProwlarrPublicIndexer" "${CONFIGURE_PS1}")"

if [[ -z "${FUNC_BODY}" ]]; then
    skip "Add-ProwlarrPublicIndexer not found — skipping local variable check"
else
    if echo "${FUNC_BODY}" | grep -qE '^\s*\$indexers\s*=\s*@\('; then
        fail "Add-ProwlarrPublicIndexer still defines a local \$indexers = @(...) array — this must be removed; the data now lives in \$IndexerDefinitions"
    else
        pass "Add-ProwlarrPublicIndexer does not define a local \$indexers variable (good — data lives in \$IndexerDefinitions)"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 8: Syntax regression guard (always runs)
# ---------------------------------------------------------------------------

section "Phase 8: Syntax Regression Guard (should always pass)"

# Basic structural checks that should hold throughout the refactor
if grep -q 'function Add-ProwlarrIndexer' "${CONFIGURE_PS1}"; then
    pass "Add-ProwlarrIndexer function still exists in configure.ps1"
else
    fail "Add-ProwlarrIndexer function was accidentally removed from configure.ps1"
fi

if grep -q 'function Add-ProwlarrPublicIndexer' "${CONFIGURE_PS1}"; then
    pass "Add-ProwlarrPublicIndexer function still exists in configure.ps1"
else
    fail "Add-ProwlarrPublicIndexer function was accidentally removed from configure.ps1"
fi

# The 5 URLs must still appear somewhere in configure.ps1 (might be in the array or elsewhere)
for expected_url in "yts.mx" "thepiratebay.org" "torrentgalaxy.to" "nyaa.si" "limetorrents"; do
    if grep -q "${expected_url}" "${CONFIGURE_PS1}"; then
        pass "URL fragment '${expected_url}' is still referenced in configure.ps1"
    else
        fail "URL fragment '${expected_url}' is no longer in configure.ps1 — data may have been accidentally deleted"
    fi
done

# The definitionName parameter must still be passed somewhere
if grep -q 'DefinitionName\|definitionName' "${CONFIGURE_PS1}"; then
    pass "definitionName field is still present in configure.ps1"
else
    fail "definitionName field has disappeared from configure.ps1 — the Prowlarr indexer payload is incomplete"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$(( PASS_COUNT + FAIL_COUNT + SKIP_COUNT ))

printf "\n%b════════════════════════════════════════════════════════════%b\n" "${CYAN}" "${NC}"
printf "  Results: %b%d passed%b  %b%d failed%b  %b%d skipped%b  (%d total)\n" \
    "${GREEN}" "${PASS_COUNT}" "${NC}" \
    "${RED}" "${FAIL_COUNT}" "${NC}" \
    "${YELLOW}" "${SKIP_COUNT}" "${NC}" \
    "${TOTAL}"
printf "%b════════════════════════════════════════════════════════════%b\n\n" "${CYAN}" "${NC}"

if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
