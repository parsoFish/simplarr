#!/bin/bash
# =============================================================================
# Simplarr — Bash: Prowlarr INDEXER_DEFINITIONS Data Structure Validation (TDD)
# =============================================================================
# Validates that the Prowlarr indexer list is extracted from local parallel
# arrays inside add_public_indexers() to a script-level INDEXER_DEFINITIONS
# array in configure.sh.
#
# Work item: Bash: Extract Prowlarr indexer definitions to a data structure
#            in configure.sh
#
# Acceptance criteria tested here:
#   1. INDEXER_DEFINITIONS is defined at script scope (outside any function)
#   2. INDEXER_DEFINITIONS contains exactly 5 entries
#   3. Each entry encodes the required fields (name, base_url, definition_name)
#   4. All 5 known indexers are present with correct URLs and definition names
#   5. add_public_indexers() references INDEXER_DEFINITIONS (not local parallel arrays)
#   6. Local parallel arrays removed from add_public_indexers()
#   7. Runtime: curl is invoked exactly once per INDEXER_DEFINITIONS entry with
#      correct JSON (definitionName + baseUrl) — curl is stubbed, no real HTTP
#   8. ShellCheck zero warnings — regression guard (should pass before and after)
#
# TDD: Phases 1–7 FAIL before implementation (local parallel arrays still
#      exist; INDEXER_DEFINITIONS is not defined). Phase 8 is a regression guard.
#
# Usage:
#   ./dev-testing/test_sh_indexer_data_structure.sh
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
# Helper: extract the body of a bash function (from "funcname() {" to
# the closing standalone "}" line at column 0).
# ---------------------------------------------------------------------------
extract_function_body() {
    local func_name="$1"
    local file="$2"
    sed -n "/^${func_name}() {/,/^}/p" "${file}"
}

# ---------------------------------------------------------------------------
# Helper: build a safe-to-source copy of configure.sh.
# Strips 'set -e' and the "# Run main function / main "$@"" tail so sourcing
# only defines functions and script-level variables.
# ---------------------------------------------------------------------------
_SAFE_CONFIGURE=""
_TMPDIR=""

setup_safe_configure() {
    _TMPDIR=$(mktemp -d)
    _SAFE_CONFIGURE="${_TMPDIR}/configure_testable.sh"
    sed '/^set -e$/d; /^# Run main function$/,$ d' "${CONFIGURE_SH}" \
        > "${_SAFE_CONFIGURE}"
}

# shellcheck disable=SC2317  # invoked indirectly via trap EXIT
cleanup() {
    if [[ -n "${_TMPDIR}" && -d "${_TMPDIR}" ]]; then
        rm -rf "${_TMPDIR}"
    fi
}
trap cleanup EXIT

if [[ ! -f "${CONFIGURE_SH}" ]]; then
    printf "%b[FATAL]%b configure.sh not found at %s\n" "${RED}" "${NC}" "${CONFIGURE_SH}"
    exit 1
fi

setup_safe_configure

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  Bash: Prowlarr INDEXER_DEFINITIONS Data Structure (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

# ---------------------------------------------------------------------------
# Phase 1: INDEXER_DEFINITIONS variable presence at script scope
# TDD: FAIL before implementation (variable not yet promoted).
# ---------------------------------------------------------------------------

section "Phase 1: INDEXER_DEFINITIONS Variable Presence (TDD — fails before implementation)"

# 1.1 — INDEXER_DEFINITIONS must be declared at the top level (not inside a function)
if grep -qE '^INDEXER_DEFINITIONS=' "${CONFIGURE_SH}"; then
    pass "INDEXER_DEFINITIONS is declared at script scope in configure.sh"
else
    fail "INDEXER_DEFINITIONS is NOT declared at script scope — the local parallel arrays inside add_public_indexers() must be promoted to a single script-level constant"
fi

# ---------------------------------------------------------------------------
# Phase 2: INDEXER_DEFINITIONS must NOT be inside a function body
# TDD: SKIP if Phase 1 failed (variable not defined yet).
# ---------------------------------------------------------------------------

section "Phase 2: INDEXER_DEFINITIONS Defined Outside Functions"

_INDEXER_DEF_LINE="$(grep -n '^INDEXER_DEFINITIONS=' "${CONFIGURE_SH}" | head -1 | cut -d: -f1 || true)"

if [[ -z "${_INDEXER_DEF_LINE}" ]]; then
    skip "INDEXER_DEFINITIONS not yet defined — skipping scope check"
else
    # Count function openings and closings before the definition line.
    # If opens > closes, the definition is still inside an unclosed function.
    _LINES_BEFORE="$(head -n "${_INDEXER_DEF_LINE}" "${CONFIGURE_SH}")"
    _FUNC_OPENS="$(echo "${_LINES_BEFORE}" | grep -cE '^[a-z_]+\(\) \{' || true)"
    _FUNC_CLOSES="$(echo "${_LINES_BEFORE}" | grep -c '^}' || true)"

    if (( _FUNC_OPENS <= _FUNC_CLOSES )); then
        pass "INDEXER_DEFINITIONS is at script scope (not inside a function body)"
    else
        fail "INDEXER_DEFINITIONS appears inside a function body — it must be a script-level constant"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: Entry count — exactly 5 indexers
# TDD: SKIP if Phase 1 failed.
# ---------------------------------------------------------------------------

section "Phase 3: Entry Count (exactly 5 entries)"

_INDEXER_DEF_LINE="$(grep -n '^INDEXER_DEFINITIONS=' "${CONFIGURE_SH}" | head -1 | cut -d: -f1 || true)"

if [[ -z "${_INDEXER_DEF_LINE}" ]]; then
    skip "Cannot check entry count — INDEXER_DEFINITIONS not defined yet"
else
    # Extract the array literal block: from INDEXER_DEFINITIONS=( to the closing )
    _ARRAY_BLOCK="$(awk "NR>=${_INDEXER_DEF_LINE}" "${CONFIGURE_SH}" | awk '/^INDEXER_DEFINITIONS=/,/^\)/' | head -20)"
    # Count lines that look like quoted entries (each entry on its own line)
    # Works for the expected format: "name|base_url|definition|impl" entries
    _ENTRY_COUNT="$(echo "${_ARRAY_BLOCK}" | grep -cE '^\s+"[^"]+\|' || true)"

    if [[ "${_ENTRY_COUNT}" -eq 5 ]]; then
        pass "INDEXER_DEFINITIONS contains exactly 5 entries (count=${_ENTRY_COUNT})"
    else
        fail "INDEXER_DEFINITIONS must contain exactly 5 entries; found ${_ENTRY_COUNT} pipe-delimited entries in the array block"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 4: Entry schema — each entry encodes all required fields
# Entries are expected in "name|base_url|definition_name|impl_name" format.
# TDD: SKIP if Phase 1 failed.
# ---------------------------------------------------------------------------

section "Phase 4: Entry Schema (name|base_url|definition_name fields per entry)"

_INDEXER_DEF_LINE="$(grep -n '^INDEXER_DEFINITIONS=' "${CONFIGURE_SH}" | head -1 | cut -d: -f1 || true)"

if [[ -z "${_INDEXER_DEF_LINE}" ]]; then
    skip "Cannot check entry schema — INDEXER_DEFINITIONS not defined yet"
else
    _ARRAY_BLOCK="$(awk "NR>=${_INDEXER_DEF_LINE}" "${CONFIGURE_SH}" | awk '/^INDEXER_DEFINITIONS=/,/^\)/' | head -20)"

    # 4.1: Entries must be pipe-delimited (the expected encoding for multi-field entries)
    if echo "${_ARRAY_BLOCK}" | grep -qE '^\s+"[^"]+\|[^"]+\|'; then
        pass "Entries use pipe-delimited format — at least 2 fields per entry"
    else
        fail "Entries do not appear to use pipe-delimited format — each entry must encode name|base_url|definition_name (and optionally impl_name)"
    fi

    # 4.2: First field (name) must be a non-empty string (checked via known names)
    if echo "${_ARRAY_BLOCK}" | grep -qE '"YTS\|'; then
        pass "First field is the indexer display name (found 'YTS' as sample)"
    else
        fail "Expected indexer name 'YTS' as first pipe-delimited field — check entry format"
    fi

    # 4.3: URL field must contain https://
    if echo "${_ARRAY_BLOCK}" | grep -q 'https://'; then
        pass "Entries include a base URL field (https:// detected)"
    else
        fail "No https:// URL found in INDEXER_DEFINITIONS entries — base URL field is required"
    fi

    # 4.4: Definition name field (Prowlarr Cardigann schema ID) must be present
    if echo "${_ARRAY_BLOCK}" | grep -q 'yts'; then
        pass "Entries include a definition name field (found 'yts' as sample)"
    else
        fail "Definition name 'yts' not found in INDEXER_DEFINITIONS — definitionName field is required for Prowlarr Cardigann lookup"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 5: All 5 expected indexers present with correct URLs and definition names
# Regression guard: these PASS before and after the refactoring because the
# data only moves, it never disappears.
# ---------------------------------------------------------------------------

section "Phase 5: Expected Indexers Present (regression guard)"

declare -A _EXPECTED_URLS=(
    ["YTS"]="yts.mx"
    ["The Pirate Bay"]="thepiratebay.org"
    ["TorrentGalaxy"]="torrentgalaxy.to"
    ["Nyaa"]="nyaa.si"
    ["LimeTorrents"]="limetorrents.lol"
)

declare -A _EXPECTED_DEFS=(
    ["YTS"]="yts"
    ["The Pirate Bay"]="thepiratebay"
    ["TorrentGalaxy"]="torrentgalaxy"
    ["Nyaa"]="nyaasi"
    ["LimeTorrents"]="limetorrents"
)

for _iname in "YTS" "The Pirate Bay" "TorrentGalaxy" "Nyaa" "LimeTorrents"; do
    _url="${_EXPECTED_URLS[$_iname]}"
    _def="${_EXPECTED_DEFS[$_iname]}"

    if grep -q "${_url}" "${CONFIGURE_SH}"; then
        pass "URL for '${_iname}' (${_url}) is present in configure.sh"
    else
        fail "URL for '${_iname}' (${_url}) is MISSING — must not be lost during refactoring"
    fi

    if grep -qF "\"${_def}\"" "${CONFIGURE_SH}"; then
        pass "Definition name '${_def}' for '${_iname}' is present in configure.sh"
    else
        fail "Definition name '${_def}' for '${_iname}' is MISSING — Prowlarr Cardigann needs this exact identifier"
    fi
done

# ---------------------------------------------------------------------------
# Phase 6: add_public_indexers() references INDEXER_DEFINITIONS
# TDD: FAIL before implementation (function still has local parallel arrays).
# ---------------------------------------------------------------------------

section "Phase 6: add_public_indexers() Uses INDEXER_DEFINITIONS (TDD — fails before implementation)"

_PUBLIC_BODY="$(extract_function_body "add_public_indexers" "${CONFIGURE_SH}")"

if [[ -z "${_PUBLIC_BODY}" ]]; then
    fail "add_public_indexers() function not found in configure.sh"
else
    # 6.1: Function body must reference INDEXER_DEFINITIONS
    if echo "${_PUBLIC_BODY}" | grep -q 'INDEXER_DEFINITIONS'; then
        pass "add_public_indexers() references INDEXER_DEFINITIONS"
    else
        fail "add_public_indexers() does NOT reference INDEXER_DEFINITIONS — it must iterate over the script-level array"
    fi

    # 6.2: Function body must contain a for loop over INDEXER_DEFINITIONS
    if echo "${_PUBLIC_BODY}" | grep -qE 'for\s.*INDEXER_DEFINITIONS'; then
        pass "add_public_indexers() contains a for-loop over INDEXER_DEFINITIONS"
    else
        fail "add_public_indexers() has no for-loop over INDEXER_DEFINITIONS — expected: for entry in \"\${INDEXER_DEFINITIONS[@]}\""
    fi

    # 6.3: Loop body must call add_indexer (verifies delegation is intact)
    if echo "${_PUBLIC_BODY}" | grep -q 'add_indexer'; then
        pass "add_public_indexers() calls add_indexer (delegation intact)"
    else
        fail "add_public_indexers() does not call add_indexer — loop must delegate to the parameterized function"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 7: Local parallel arrays removed from add_public_indexers()
# TDD: FAIL before implementation (local arrays are still present).
# ---------------------------------------------------------------------------

section "Phase 7: Local Parallel Arrays Removed (TDD — fails before implementation)"

_PUBLIC_BODY="$(extract_function_body "add_public_indexers" "${CONFIGURE_SH}")"

if [[ -z "${_PUBLIC_BODY}" ]]; then
    skip "add_public_indexers() not found — skipping local array check"
else
    # 7.1: local -a names=( must be gone
    if echo "${_PUBLIC_BODY}" | grep -qE 'local -a names=\('; then
        fail "add_public_indexers() still defines 'local -a names=(...)' — this parallel array must be removed; data lives in INDEXER_DEFINITIONS"
    else
        pass "add_public_indexers() has no local 'names' parallel array (data lives in INDEXER_DEFINITIONS)"
    fi

    # 7.2: local -a base_urls=( must be gone
    if echo "${_PUBLIC_BODY}" | grep -qE 'local -a base_urls=\('; then
        fail "add_public_indexers() still defines 'local -a base_urls=(...)' — this parallel array must be removed"
    else
        pass "add_public_indexers() has no local 'base_urls' parallel array"
    fi

    # 7.3: local -a def_names=( must be gone
    if echo "${_PUBLIC_BODY}" | grep -qE 'local -a def_names=\('; then
        fail "add_public_indexers() still defines 'local -a def_names=(...)' — this parallel array must be removed"
    else
        pass "add_public_indexers() has no local 'def_names' parallel array"
    fi

    # 7.4: local -a impl_names=( must be gone
    if echo "${_PUBLIC_BODY}" | grep -qE 'local -a impl_names=\('; then
        fail "add_public_indexers() still defines 'local -a impl_names=(...)' — this parallel array must be removed"
    else
        pass "add_public_indexers() has no local 'impl_names' parallel array"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 8: Runtime Unit Tests — stub curl, assert invoked once per entry
# TDD: FAIL before implementation (INDEXER_DEFINITIONS undefined → count 0;
#      but add_public_indexers still calls add_indexer 5 times from local arrays).
#
# Each subtest sources the safe configure.sh, overrides curl to capture and
# count calls, then invokes add_public_indexers() and inspects the results.
# ---------------------------------------------------------------------------

section "Phase 8: Runtime Unit Tests — curl stubbed, one call per INDEXER_DEFINITIONS entry (TDD)"

printf "\n"
info "Sourcing safe configure.sh and counting INDEXER_DEFINITIONS entries..."
printf "\n"

# Determine expected call count from INDEXER_DEFINITIONS in the safe copy
_EXPECTED_CALLS=0
_INDEXER_DEF_LINE_IN_SAFE="$(grep -n '^INDEXER_DEFINITIONS=' "${_SAFE_CONFIGURE}" | head -1 | cut -d: -f1 || true)"
if [[ -n "${_INDEXER_DEF_LINE_IN_SAFE}" ]]; then
    _ARRAY_BLOCK_SAFE="$(awk "NR>=${_INDEXER_DEF_LINE_IN_SAFE}" "${_SAFE_CONFIGURE}" | awk '/^INDEXER_DEFINITIONS=/,/^\)/' | head -20)"
    _EXPECTED_CALLS="$(echo "${_ARRAY_BLOCK_SAFE}" | grep -cE '^\s+"[^"]+\|' || true)"
fi

info "Expected curl calls (= INDEXER_DEFINITIONS entry count): ${_EXPECTED_CALLS}"
printf "\n"

# 8.1 — curl is invoked exactly N times (N = INDEXER_DEFINITIONS count)
_CALL_LOG="${_TMPDIR}/curl_calls.log"
_ACTUAL_CALLS=0

bash -c "
    _log='${_CALL_LOG}'
    _call_count=0

    curl() {
        _call_count=\$(( _call_count + 1 ))
        local body='' key=''
        local i=0
        local -a args=(\"\$@\")
        while [[ \$i -lt \${#args[@]} ]]; do
            case \"\${args[\$i]}\" in
                -d)
                    body=\"\${args[\$((i+1))]}\"
                    (( i++ )) || true
                    ;;
                -H)
                    local hdr=\"\${args[\$((i+1))]}\"
                    if [[ \"\${hdr}\" =~ ^X-Api-Key: ]]; then
                        key=\"\${hdr#X-Api-Key: }\"
                    fi
                    (( i++ )) || true
                    ;;
            esac
            (( i++ )) || true
        done
        printf 'CALL=%d KEY=%s BODY=%s\n' \"\${_call_count}\" \"\${key}\" \"\${body}\" >> \"\${_log}\"
        printf '{\"id\": %d}' \"\${_call_count}\"
    }
    export -f curl

    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

    PROWLARR_URL='http://mock-prowlarr:9696'

    add_public_indexers 'test-key-abc' >/dev/null 2>&1 || true

    echo \"\${_call_count}\" > '${_TMPDIR}/actual_calls.txt'
" 2>/dev/null || true

if [[ -f "${_TMPDIR}/actual_calls.txt" ]]; then
    _ACTUAL_CALLS="$(cat "${_TMPDIR}/actual_calls.txt")"
fi

if [[ "${_ACTUAL_CALLS}" -eq "${_EXPECTED_CALLS}" ]] && [[ "${_EXPECTED_CALLS}" -eq 5 ]]; then
    pass "curl invoked exactly 5 times — matches INDEXER_DEFINITIONS entry count (${_EXPECTED_CALLS})"
elif [[ "${_EXPECTED_CALLS}" -eq 0 ]]; then
    fail "INDEXER_DEFINITIONS has 0 entries (not yet implemented); curl was called ${_ACTUAL_CALLS} times from local arrays — expected 0 to enforce the refactor drives the count"
else
    fail "curl invoked ${_ACTUAL_CALLS} times; expected ${_EXPECTED_CALLS} (INDEXER_DEFINITIONS entry count)"
fi

# 8.2–8.16 — Per-indexer payload correctness (X-Api-Key + definitionName + baseUrl)
printf "\n"
info "Checking per-indexer payloads from captured curl calls..."
printf "\n"

declare -a _PAYLOAD_MATRIX=(
    "yts|yts.mx|test-key-abc"
    "thepiratebay|thepiratebay.org|test-key-abc"
    "torrentgalaxy|torrentgalaxy.to|test-key-abc"
    "nyaasi|nyaa.si|test-key-abc"
    "limetorrents|limetorrents.lol|test-key-abc"
)

if [[ ! -f "${_CALL_LOG}" ]]; then
    for _entry in "${_PAYLOAD_MATRIX[@]}"; do
        IFS='|' read -r _def _url_frag _key <<< "${_entry}"
        fail "add_public_indexers(${_def}) — no curl calls captured (add_public_indexers did not call add_indexer or function missing)"
    done
else
    for _entry in "${_PAYLOAD_MATRIX[@]}"; do
        IFS='|' read -r _def _url_frag _key <<< "${_entry}"

        # 8.x-i: Correct X-Api-Key forwarded
        if grep -q "KEY=${_key}" "${_CALL_LOG}"; then
            pass "add_public_indexers → add_indexer(${_def}) — X-Api-Key '${_key}' forwarded to curl"
        else
            fail "add_public_indexers → add_indexer(${_def}) — X-Api-Key '${_key}' NOT forwarded to curl"
        fi

        # 8.x-ii: definitionName present in some curl call body
        if grep -q "\"${_def}\"" "${_CALL_LOG}"; then
            pass "add_public_indexers → add_indexer(${_def}) — definitionName '${_def}' present in a curl payload"
        else
            fail "add_public_indexers → add_indexer(${_def}) — definitionName '${_def}' NOT found in any captured curl payload"
        fi

        # 8.x-iii: baseUrl fragment present in some curl call body
        if grep -q "${_url_frag}" "${_CALL_LOG}"; then
            pass "add_public_indexers → add_indexer(${_def}) — base URL fragment '${_url_frag}' present in a curl payload"
        else
            fail "add_public_indexers → add_indexer(${_def}) — base URL fragment '${_url_frag}' NOT found in any captured curl payload"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 9: ShellCheck integration — zero warnings (regression guard)
# This PASSES before and after the refactoring.
# ---------------------------------------------------------------------------

section "Phase 9: ShellCheck Zero Warnings (Integration — regression guard)"

if command -v shellcheck >/dev/null 2>&1; then
    _SC_OUTPUT="$(shellcheck --shell=bash "${CONFIGURE_SH}" 2>&1 || true)"
    _SC_COUNT="$(echo "${_SC_OUTPUT}" | grep -c '^In configure.sh' || true)"

    if [[ "${_SC_COUNT}" -eq 0 ]]; then
        pass "ShellCheck reports zero warnings/errors in configure.sh"
    else
        fail "ShellCheck found ${_SC_COUNT} issue(s) in configure.sh — the INDEXER_DEFINITIONS refactor must maintain zero ShellCheck warnings"
        printf '%s\n' "${_SC_OUTPUT}" | head -20 | while IFS= read -r _l; do printf '    %s\n' "${_l}"; done
    fi
else
    skip "ShellCheck not installed — install via 'apt-get install shellcheck' or 'brew install shellcheck'"
fi

# ---------------------------------------------------------------------------
# Phase 10: Syntax validation (regression guard)
# Verifies configure.sh is still valid bash after the refactoring.
# ---------------------------------------------------------------------------

section "Phase 10: Bash Syntax Validation (regression guard)"

if bash -n "${CONFIGURE_SH}" 2>/dev/null; then
    pass "configure.sh passes 'bash -n' syntax check"
else
    _SYNTAX_ERR="$(bash -n "${CONFIGURE_SH}" 2>&1 || true)"
    fail "configure.sh has bash syntax errors — the INDEXER_DEFINITIONS refactor broke syntax"
    printf '%s\n' "${_SYNTAX_ERR}" | while IFS= read -r _l; do printf '    %s\n' "${_l}"; done
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
    printf "  %bTDD note:%b Phases 1–8 failures indicate the implementation has not been\n" "${YELLOW}" "${NC}"
    printf "  written yet — expected before the refactoring. Phases 9–10 failures\n"
    printf "  indicate regressions that must be fixed regardless of TDD phase.\n\n"
    exit 1
fi
exit 0
