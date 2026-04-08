#!/bin/bash
# =============================================================================
# Simplarr — configure.sh Refactoring Validation (TDD Test Suite)
# =============================================================================
# Validates the two-part refactoring of configure.sh:
#   (1) add_indexer()                   — extracted from 5 copy-paste curl blocks
#                                         inside add_public_indexers(); called in a
#                                         loop over an indexer config array
#   (2) add_qbittorrent_download_client() — consolidated from the two separate
#                                           add_qbittorrent_to_radarr() and
#                                           add_qbittorrent_to_sonarr() functions;
#                                           accepts service-specific parameters
#
# Test Phases:
#   1  New function presence         — TDD: FAIL before impl, PASS after
#   2  Structural deduplication      — TDD: FAIL before impl, PASS after
#   3  Indexer data completeness     — Regression guard: PASS before and after
#   4  Download client field guard   — Regression guard: PASS before and after
#   5  Backward compatibility        — Regression guard: existing test.sh Phase 7
#   6  Payload capture equivalence   — TDD: FAIL before impl, PASS after
#
# Usage:
#   ./dev-testing/test_configure_refactor.sh
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
# Header
# ---------------------------------------------------------------------------

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  configure.sh Refactoring Validation (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

if [[ ! -f "${CONFIGURE_SH}" ]]; then
    printf "%b[FATAL]%b configure.sh not found at %s\n" "${RED}" "${NC}" "${CONFIGURE_SH}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: extract function body
# Extracts lines from "funcname()" to the closing standalone "}" line.
# Works for any function whose closing brace sits at column 0 (unindented).
# ---------------------------------------------------------------------------
extract_function_body() {
    local func_name="$1"
    local file="$2"
    sed -n "/^${func_name}()/,/^}/p" "${file}"
}

# ---------------------------------------------------------------------------
# Helper: create a safe-to-source copy of configure.sh
# Removes 'set -e' (prevents unintended exits in test harness) and strips the
# bottom "main "$@"" invocation so sourcing only defines functions.
# ---------------------------------------------------------------------------
_SAFE_CONFIGURE=""
_TMPDIR_SAFE=""

setup_safe_configure() {
    _TMPDIR_SAFE=$(mktemp -d)
    _SAFE_CONFIGURE="${_TMPDIR_SAFE}/configure_testable.sh"
    # Remove 'set -e' line; remove from "# Run main function" comment to EOF
    sed '/^set -e$/d; /^# Run main function$/,$ d' "${CONFIGURE_SH}" \
        > "${_SAFE_CONFIGURE}"
}

cleanup() {
    if [[ -n "${_TMPDIR_SAFE}" && -d "${_TMPDIR_SAFE}" ]]; then
        rm -rf "${_TMPDIR_SAFE}"
    fi
    if [[ -n "${_TMPDIR_PHASE6:-}" && -d "${_TMPDIR_PHASE6}" ]]; then
        rm -rf "${_TMPDIR_PHASE6}"
    fi
}
trap cleanup EXIT

setup_safe_configure

# ---------------------------------------------------------------------------
# Phase 1: New Function Presence
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 1: New Function Presence (TDD — will fail before implementation)"

printf "\n"
info "Checking for new parameterized functions required by the refactoring"
printf "\n"

# 1.1 — add_indexer() must be defined at the top level of configure.sh
if grep -qE "^add_indexer\(\)" "${CONFIGURE_SH}"; then
    pass "configure.sh — add_indexer() function is defined"
else
    fail "configure.sh — add_indexer() is NOT defined (TDD: extract from duplicate curl blocks)"
fi

# 1.2 — add_qbittorrent_download_client() must be defined at the top level
if grep -qE "^add_qbittorrent_download_client\(\)" "${CONFIGURE_SH}"; then
    pass "configure.sh — add_qbittorrent_download_client() function is defined"
else
    fail "configure.sh — add_qbittorrent_download_client() is NOT defined (TDD: consolidate two DL-client functions)"
fi

# ---------------------------------------------------------------------------
# Phase 2: Structural Deduplication
# These tests FAIL before implementation and PASS after.
# ---------------------------------------------------------------------------

section "Phase 2: Structural Deduplication (TDD — will fail before implementation)"

# ---- 2a: add_public_indexers() loop structure ----

printf "\n"
info "add_public_indexers() must delegate to add_indexer via a loop (no 5 duplicate curl blocks)"
printf "\n"

_ADD_PUBLIC_BODY=$(extract_function_body "add_public_indexers" "${CONFIGURE_SH}")

# 2.1 — add_public_indexers() body must call add_indexer
if echo "${_ADD_PUBLIC_BODY}" | grep -q "add_indexer"; then
    pass "add_public_indexers() — calls add_indexer (loop-based dispatch)"
else
    fail "add_public_indexers() — does NOT call add_indexer (TDD: replace 5 curl blocks with a loop)"
fi

# 2.2 — add_public_indexers() body must NOT contain direct curl POSTs to /api/v1/indexer
# After refactoring, the direct curl call lives inside add_indexer(), not here.
_DIRECT_CURL_COUNT=$(echo "${_ADD_PUBLIC_BODY}" | grep -c '/api/v1/indexer' || true)
if [[ "${_DIRECT_CURL_COUNT}" -eq 0 ]]; then
    pass "add_public_indexers() — zero direct curl calls to /api/v1/indexer (delegated to add_indexer)"
else
    fail "add_public_indexers() — found ${_DIRECT_CURL_COUNT} direct curl call(s) to /api/v1/indexer (expected 0)"
fi

# 2.3 — add_public_indexers() body must contain a loop construct
if echo "${_ADD_PUBLIC_BODY}" | grep -qE '\bfor\b|\bwhile\b'; then
    pass "add_public_indexers() — contains a loop construct (for/while)"
else
    fail "add_public_indexers() — no loop construct found (TDD: add a for-loop over indexer config array)"
fi

# 2.4 — add_indexer() body must contain a curl call to /api/v1/indexer
# Validates the function encapsulates the real API call.
_ADD_INDEXER_BODY=$(extract_function_body "add_indexer" "${CONFIGURE_SH}")
if echo "${_ADD_INDEXER_BODY}" | grep -q '/api/v1/indexer'; then
    pass "add_indexer() — body contains curl call to /api/v1/indexer"
else
    fail "add_indexer() — body does NOT contain curl call to /api/v1/indexer (TDD: move curl logic here)"
fi

# ---- 2b: download client consolidation ----

printf "\n"
info "add_qbittorrent_download_client() must be the single implementation, called twice from main"
printf "\n"

# 2.5 — add_qbittorrent_download_client must appear ≥3 times:
# 1 definition line + at least 2 call sites in main() (Radarr + Sonarr)
_DL_CLIENT_OCCURRENCES=$(grep -c "add_qbittorrent_download_client" "${CONFIGURE_SH}" || true)
if [[ "${_DL_CLIENT_OCCURRENCES}" -ge 3 ]]; then
    pass "configure.sh — add_qbittorrent_download_client appears ${_DL_CLIENT_OCCURRENCES} times (≥3: 1 def + 2 call sites)"
else
    fail "configure.sh — add_qbittorrent_download_client appears ${_DL_CLIENT_OCCURRENCES} times (expected ≥3: 1 def + 2 calls)"
fi

# 2.6 — add_qbittorrent_download_client() body must contain the shared curl payload fields
# that were duplicated across both original functions
_DL_CLIENT_BODY=$(extract_function_body "add_qbittorrent_download_client" "${CONFIGURE_SH}")
if echo "${_DL_CLIENT_BODY}" | grep -q '/downloadclient'; then
    pass "add_qbittorrent_download_client() — body contains curl call to /downloadclient endpoint"
else
    fail "add_qbittorrent_download_client() — body does NOT call /downloadclient (TDD: consolidate DL client curl here)"
fi

# ---------------------------------------------------------------------------
# Phase 3: Indexer Data Completeness
# Regression guards — these PASS before and after the refactoring.
# A failure here means data was lost during the extraction.
# ---------------------------------------------------------------------------

section "Phase 3: Indexer Data Completeness (Regression Guards)"

printf "\n"
info "All 5 indexer names, definitionNames, and base URL fragments must survive the refactoring"
printf "\n"

# 3.1–3.5 — Indexer display names (appear in single-quoted JSON as literal "YTS" etc.)
declare -a _INDEXER_NAMES=("YTS" "The Pirate Bay" "TorrentGalaxy" "Nyaa" "LimeTorrents")
for _name in "${_INDEXER_NAMES[@]}"; do
    if grep -qF "\"${_name}\"" "${CONFIGURE_SH}"; then
        pass "configure.sh — indexer name \"${_name}\" is present"
    else
        fail "configure.sh — indexer name \"${_name}\" MISSING (data lost in refactoring?)"
    fi
done

printf "\n"

# 3.6–3.10 — Prowlarr definitionNames (used to look up the indexer schema)
declare -a _DEFINITION_NAMES=("yts" "thepiratebay" "torrentgalaxy" "nyaasi" "limetorrents")
for _defn in "${_DEFINITION_NAMES[@]}"; do
    if grep -qF "\"${_defn}\"" "${CONFIGURE_SH}"; then
        pass "configure.sh — definitionName \"${_defn}\" is present"
    else
        fail "configure.sh — definitionName \"${_defn}\" MISSING (data lost in refactoring?)"
    fi
done

printf "\n"

# 3.11–3.15 — Base URL fragments for each indexer
declare -a _BASE_URL_FRAGS=("yts.mx" "thepiratebay.org" "torrentgalaxy.to" "nyaa.si" "limetorrents.lol")
for _frag in "${_BASE_URL_FRAGS[@]}"; do
    if grep -q "${_frag}" "${CONFIGURE_SH}"; then
        pass "configure.sh — base URL fragment \"${_frag}\" is present"
    else
        fail "configure.sh — base URL fragment \"${_frag}\" MISSING (data lost in refactoring?)"
    fi
done

# ---------------------------------------------------------------------------
# Phase 4: Download Client Field Preservation
# Regression guards — the service-specific field names that differ between
# Radarr and Sonarr must survive the consolidation into one function.
#
# Note: these field names appear inside double-quoted bash heredocs as
# \"movieCategory\" (backslash-escaped), so we search for the name alone
# without surrounding quote characters to match in both styles.
# ---------------------------------------------------------------------------

section "Phase 4: Download Client Field Preservation (Regression Guards)"

printf "\n"
info "Service-specific JSON field names must be present (will be passed as parameters)"
printf "\n"

# 4.1–4.3 — Radarr-specific fields
declare -a _RADARR_FIELDS=("movieCategory" "recentMoviePriority" "olderMoviePriority")
for _field in "${_RADARR_FIELDS[@]}"; do
    if grep -q "${_field}" "${CONFIGURE_SH}"; then
        pass "configure.sh — Radarr field \"${_field}\" is present"
    else
        fail "configure.sh — Radarr field \"${_field}\" MISSING (data lost in consolidation?)"
    fi
done

printf "\n"

# 4.4–4.6 — Sonarr-specific fields
declare -a _SONARR_FIELDS=("tvCategory" "recentTvPriority" "olderTvPriority")
for _field in "${_SONARR_FIELDS[@]}"; do
    if grep -q "${_field}" "${CONFIGURE_SH}"; then
        pass "configure.sh — Sonarr field \"${_field}\" is present"
    else
        fail "configure.sh — Sonarr field \"${_field}\" MISSING (data lost in consolidation?)"
    fi
done

# ---------------------------------------------------------------------------
# Phase 5: Backward Compatibility
# The existing test.sh Phase 7 explicitly checks for these two function names.
# The implementation MUST keep them defined (as thin wrappers if necessary)
# so the 83+ existing test assertions continue to pass unchanged.
# ---------------------------------------------------------------------------

section "Phase 5: Backward Compatibility (Regression Guards — required by test.sh Phase 7)"

printf "\n"
info "Old function names must remain defined so test.sh Phase 7 assertions stay green"
printf "\n"

# 5.1 — add_qbittorrent_to_radarr() must still be defined at top level
if grep -qE "^add_qbittorrent_to_radarr\(\)" "${CONFIGURE_SH}"; then
    pass "configure.sh — add_qbittorrent_to_radarr() still defined (backward compat with test.sh)"
else
    fail "configure.sh — add_qbittorrent_to_radarr() is MISSING — breaks test.sh Phase 7 check"
fi

# 5.2 — add_qbittorrent_to_sonarr() must still be defined at top level
if grep -qE "^add_qbittorrent_to_sonarr\(\)" "${CONFIGURE_SH}"; then
    pass "configure.sh — add_qbittorrent_to_sonarr() still defined (backward compat with test.sh)"
else
    fail "configure.sh — add_qbittorrent_to_sonarr() is MISSING — breaks test.sh Phase 7 check"
fi

# ---------------------------------------------------------------------------
# Phase 6: Payload Capture Equivalence
# Runtime tests using a bash-level curl override (no real network calls).
# These tests FAIL before implementation (function missing) and PASS after
# (function exists and produces expected payloads).
#
# Design: a subshell sources the safe copy of configure.sh, overrides curl
# to write captured arguments to a temp file, then calls the target function.
# We then assert the captured payload contains the expected fields.
# ---------------------------------------------------------------------------

section "Phase 6: Payload Capture Equivalence (TDD — will fail before implementation)"

_TMPDIR_PHASE6=$(mktemp -d)

# ---- 6a: add_indexer() payloads ----

printf "\n"
info "Phase 6a: add_indexer() — payload capture for all 5 indexers"
printf "\n"

# First, check if add_indexer exists in the safe-sourced version before testing payloads.
_INDEXER_FUNC_EXISTS=false
if bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1
    declare -f add_indexer > /dev/null 2>&1
" 2>/dev/null; then
    _INDEXER_FUNC_EXISTS=true
fi

if [[ "${_INDEXER_FUNC_EXISTS}" != "true" ]]; then
    fail "add_indexer() — function not available after sourcing configure.sh (TDD: implementation required)"
    skip "add_indexer payload capture — skipped (function missing)"
else
    # Indexer test matrix: "name|base_url|definitionName"
    # These mirror the 5 original hardcoded curl blocks in add_public_indexers().
    declare -a _INDEXER_MATRIX=(
        "YTS|https://yts.mx|yts"
        "The Pirate Bay|https://thepiratebay.org|thepiratebay"
        "TorrentGalaxy|https://torrentgalaxy.to|torrentgalaxy"
        "Nyaa|https://nyaa.si|nyaasi"
        "LimeTorrents|https://www.limetorrents.lol|limetorrents"
    )

    for _entry in "${_INDEXER_MATRIX[@]}"; do
        IFS='|' read -r _iname _iurl _idefn <<< "${_entry}"
        _CAPTURE_FILE="${_TMPDIR_PHASE6}/indexer_${_idefn}.txt"

        # Run in an isolated subshell:
        # 1. Override curl to capture the -d (body) and X-Api-Key header arguments
        # 2. Source the safe configure.sh to get add_indexer defined
        # 3. Call add_indexer with test values
        bash -c "
            _capture='${_CAPTURE_FILE}'

            # curl override: extract -d body and X-Api-Key header; write to capture file
            curl() {
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
                printf 'KEY=%s\nBODY=%s\n' \"\${key}\" \"\${body}\" > \"\${_capture}\"
                echo '{\"id\": 1}'
            }
            export -f curl

            source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

            PROWLARR_URL='http://mock-prowlarr:9696'
            add_indexer 'test-api-key-123' '${_iname}' '${_iurl}' '${_idefn}' >/dev/null 2>&1 || true
        " 2>/dev/null

        if [[ ! -f "${_CAPTURE_FILE}" ]]; then
            fail "add_indexer(${_idefn}) — no payload captured (curl not called or function errored)"
            continue
        fi

        # 6a-i: X-Api-Key header forwarded correctly
        if grep -q "KEY=test-api-key-123" "${_CAPTURE_FILE}"; then
            pass "add_indexer(${_idefn}) — X-Api-Key header passed to curl"
        else
            fail "add_indexer(${_idefn}) — X-Api-Key header NOT forwarded to curl"
        fi

        # 6a-ii: definitionName in payload
        if grep -q "${_idefn}" "${_CAPTURE_FILE}"; then
            pass "add_indexer(${_idefn}) — definitionName \"${_idefn}\" in captured payload"
        else
            fail "add_indexer(${_idefn}) — definitionName \"${_idefn}\" NOT found in captured payload"
        fi

        # 6a-iii: base URL in payload
        _url_frag="${_iurl#https://}"
        _url_frag="${_url_frag#http://}"
        if grep -q "${_url_frag}" "${_CAPTURE_FILE}"; then
            pass "add_indexer(${_idefn}) — base URL fragment \"${_url_frag}\" in captured payload"
        else
            fail "add_indexer(${_idefn}) — base URL fragment \"${_url_frag}\" NOT found in captured payload"
        fi
    done
fi

# ---- 6b: add_qbittorrent_download_client() payloads ----

printf "\n"
info "Phase 6b: add_qbittorrent_download_client() — payload capture (Radarr vs Sonarr)"
printf "\n"

_DL_FUNC_EXISTS=false
if bash -c "
    source '${_SAFE_CONFIGURE}' >/dev/null 2>&1
    declare -f add_qbittorrent_download_client > /dev/null 2>&1
" 2>/dev/null; then
    _DL_FUNC_EXISTS=true
fi

if [[ "${_DL_FUNC_EXISTS}" != "true" ]]; then
    fail "add_qbittorrent_download_client() — function not available after sourcing (TDD: implementation required)"
    skip "download client Radarr payload — skipped (function missing)"
    skip "download client Sonarr payload — skipped (function missing)"
else
    # Expected consolidated function signature (based on work item description):
    #   add_qbittorrent_download_client \
    #       <service_url> <api_key> \
    #       <category_field> <category_value> \
    #       <recent_priority_field> <older_priority_field>
    #
    # Radarr call: add_qbittorrent_download_client "$RADARR_URL" "$RADARR_API_KEY" \
    #                "movieCategory" "radarr" "recentMoviePriority" "olderMoviePriority"
    # Sonarr call: add_qbittorrent_download_client "$SONARR_URL" "$SONARR_API_KEY" \
    #                "tvCategory" "sonarr" "recentTvPriority" "olderTvPriority"

    # --- Radarr-style call ---
    _RADARR_CAP="${_TMPDIR_PHASE6}/dl_radarr.txt"

    bash -c "
        _capture='${_RADARR_CAP}'

        curl() {
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
            printf 'KEY=%s\nBODY=%s\n' \"\${key}\" \"\${body}\" > \"\${_capture}\"
            echo '{\"id\": 1}'
        }
        export -f curl

        source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

        QBITTORRENT_HOST='qbittorrent'
        QB_USERNAME='admin'
        QB_PASSWORD='testpass'

        add_qbittorrent_download_client \
            'http://mock-radarr:7878' 'radarr-key-abc' \
            'movieCategory' 'radarr' \
            'recentMoviePriority' 'olderMoviePriority' >/dev/null 2>&1 || true
    " 2>/dev/null

    if [[ -f "${_RADARR_CAP}" ]]; then
        # 6b-i: X-Api-Key
        if grep -q "KEY=radarr-key-abc" "${_RADARR_CAP}"; then
            pass "add_qbittorrent_download_client(radarr) — X-Api-Key header passed to curl"
        else
            fail "add_qbittorrent_download_client(radarr) — X-Api-Key header NOT forwarded to curl"
        fi
        # 6b-ii: Radarr category field in body
        if grep -q "movieCategory" "${_RADARR_CAP}"; then
            pass "add_qbittorrent_download_client(radarr) — \"movieCategory\" field present in payload"
        else
            fail "add_qbittorrent_download_client(radarr) — \"movieCategory\" field MISSING from payload"
        fi
        # 6b-iii: Radarr priority fields in body
        if grep -q "recentMoviePriority" "${_RADARR_CAP}"; then
            pass "add_qbittorrent_download_client(radarr) — \"recentMoviePriority\" field present in payload"
        else
            fail "add_qbittorrent_download_client(radarr) — \"recentMoviePriority\" field MISSING from payload"
        fi
        # 6b-iv: Sonarr-specific fields must NOT appear in Radarr payload
        if ! grep -q "tvCategory" "${_RADARR_CAP}"; then
            pass "add_qbittorrent_download_client(radarr) — \"tvCategory\" correctly absent from Radarr payload"
        else
            fail "add_qbittorrent_download_client(radarr) — \"tvCategory\" should NOT appear in Radarr payload"
        fi
    else
        fail "add_qbittorrent_download_client(radarr) — no payload captured (curl not called or function errored)"
        skip "add_qbittorrent_download_client(radarr) — remaining payload checks skipped"
    fi

    # --- Sonarr-style call ---
    _SONARR_CAP="${_TMPDIR_PHASE6}/dl_sonarr.txt"

    bash -c "
        _capture='${_SONARR_CAP}'

        curl() {
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
            printf 'KEY=%s\nBODY=%s\n' \"\${key}\" \"\${body}\" > \"\${_capture}\"
            echo '{\"id\": 1}'
        }
        export -f curl

        source '${_SAFE_CONFIGURE}' >/dev/null 2>&1

        QBITTORRENT_HOST='qbittorrent'
        QB_USERNAME='admin'
        QB_PASSWORD='testpass'

        add_qbittorrent_download_client \
            'http://mock-sonarr:8989' 'sonarr-key-xyz' \
            'tvCategory' 'sonarr' \
            'recentTvPriority' 'olderTvPriority' >/dev/null 2>&1 || true
    " 2>/dev/null

    if [[ -f "${_SONARR_CAP}" ]]; then
        # 6b-v: X-Api-Key
        if grep -q "KEY=sonarr-key-xyz" "${_SONARR_CAP}"; then
            pass "add_qbittorrent_download_client(sonarr) — X-Api-Key header passed to curl"
        else
            fail "add_qbittorrent_download_client(sonarr) — X-Api-Key header NOT forwarded to curl"
        fi
        # 6b-vi: Sonarr category field in body
        if grep -q "tvCategory" "${_SONARR_CAP}"; then
            pass "add_qbittorrent_download_client(sonarr) — \"tvCategory\" field present in payload"
        else
            fail "add_qbittorrent_download_client(sonarr) — \"tvCategory\" field MISSING from payload"
        fi
        # 6b-vii: Sonarr priority fields in body
        if grep -q "recentTvPriority" "${_SONARR_CAP}"; then
            pass "add_qbittorrent_download_client(sonarr) — \"recentTvPriority\" field present in payload"
        else
            fail "add_qbittorrent_download_client(sonarr) — \"recentTvPriority\" field MISSING from payload"
        fi
        # 6b-viii: Radarr-specific fields must NOT appear in Sonarr payload
        if ! grep -q "movieCategory" "${_SONARR_CAP}"; then
            pass "add_qbittorrent_download_client(sonarr) — \"movieCategory\" correctly absent from Sonarr payload"
        else
            fail "add_qbittorrent_download_client(sonarr) — \"movieCategory\" should NOT appear in Sonarr payload"
        fi
    else
        fail "add_qbittorrent_download_client(sonarr) — no payload captured (curl not called or function errored)"
        skip "add_qbittorrent_download_client(sonarr) — remaining payload checks skipped"
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
    printf "\n  TDD note: Phase 1, 2, and 6 failures mean the implementation\n"
    printf "  has not been written yet — expected before the refactoring.\n"
    printf "  Phase 3, 4, and 5 failures mean data was lost during refactoring.\n\n"
    exit 1
fi
