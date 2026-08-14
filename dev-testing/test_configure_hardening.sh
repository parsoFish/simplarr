#!/bin/bash
# =============================================================================
# configure.sh / configure.ps1 Hardening Tests (PR #30 review findings)
# =============================================================================
# Specifies the safe Overseerr wiring behaviour and honest error reporting
# required after the PR #30 adversarial review:
#
#   Phase 1  Overseerr wiring safety (configure.sh)
#            - existence check matches by hostname, not first id
#            - existing entries are skipped, never overwritten via PUT
#            - verification failure aborts the function instead of POSTing
#              a duplicate (transient outage must not recreate issue #29)
#            - no set -e fragile grep pipeline for id extraction
#            - shared check_overseerr_service helper (single edit site)
#   Phase 2  Indexer error reporting (configure.sh)
#            - add_indexer reports the real HTTP status on failure instead
#              of mislabeling every error as "may already exist"
#   Phase 3  configure.ps1 correctness on Windows PowerShell 5.1
#            - UTF-8 BOM present (mojibake guard)
#            - no .Count on a possibly-scalar Invoke-RestMethod result
#            - no -ErrorAction SilentlyContinue on Overseerr settings GET
#              (it cannot suppress statement-terminating HTTP errors)
#            - shared Test-OverseerrServiceConfigured helper
#   Phase 4  configure.sh / configure.ps1 message parity
#
# These tests are written BEFORE implementation (TDD red phase).
#
# Usage:
#   ./dev-testing/test_configure_hardening.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURE_SH="${PROJECT_ROOT}/configure.sh"
CONFIGURE_PS1="${PROJECT_ROOT}/configure.ps1"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

PASS_COUNT=0
FAIL_COUNT=0

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
    printf "%b%s%b\n" "${CYAN}" \
        "────────────────────────────────────────────────────────────" "${NC}"
}

# Extract a function body from configure.sh.
# Matches from "funcname()" to the first closing "}" at column 0.
extract_sh_function() {
    local func_name=$1
    awk "/^${func_name}\(\)/,/^\}/" "${CONFIGURE_SH}"
}

# Extract a function body from configure.ps1.
# Matches from "function FuncName" to the next "function " at column 0
# (or EOF), which is enough for grep-based assertions.
extract_ps1_function() {
    local func_name=$1
    awk "/^function ${func_name}/{found=1} found && /^function /{if (seen) exit; seen=1} found" \
        "${CONFIGURE_PS1}"
}

printf "\n%b" "${BOLD}${CYAN}"
printf "════════════════════════════════════════════════════════════\n"
printf "  configure.sh / configure.ps1 Hardening Tests\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

if [[ ! -f "${CONFIGURE_SH}" || ! -f "${CONFIGURE_PS1}" ]]; then
    fail "configure.sh or configure.ps1 not found — cannot run hardening tests"
    exit 1
fi

# =============================================================================
# Phase 1: Overseerr wiring safety (configure.sh)
# =============================================================================

section "Phase 1: Overseerr wiring safety (configure.sh)"

for svc in radarr sonarr; do
    func="add_${svc}_to_overseerr"
    host_var="RADARR_HOST"
    [[ "${svc}" == "sonarr" ]] && host_var="SONARR_HOST"

    printf "\n"
    info "${func} — skip-if-exists by hostname, no destructive PUT"

    FUNC_BODY=$(extract_sh_function "${func}")

    # 1a — never PUT to Overseerr settings: an existing entry may carry user
    # customizations (quality profile, 4k flag, tags) that a defaults-built
    # PUT body would silently destroy (Overseerr PUT replaces, not merges).
    if echo "${FUNC_BODY}" | grep -q -- "-X PUT"; then
        fail "${func} — still PUTs to Overseerr settings (overwrites user customizations)"
    else
        pass "${func} — no PUT to Overseerr settings (existing entries preserved)"
    fi

    # 1b — no id-suffixed settings URL (only used by the PUT upsert)
    if echo "${FUNC_BODY}" | grep -qE "settings/${svc}/\\\$"; then
        fail "${func} — still targets settings/${svc}/<id> (upsert path must be removed)"
    else
        pass "${func} — no settings/${svc}/<id> URL"
    fi

    # 1c — existence must be decided by hostname match against the instance
    # this script manages, not by 'the array has a first id' (which grabs a
    # 4K or differently-purposed instance when several are configured).
    if echo "${FUNC_BODY}" | grep -q "${host_var}"; then
        pass "${func} — existence check references \${${host_var}} (hostname match)"
    else
        fail "${func} — existence check does not match by \${${host_var}} hostname"
    fi

    # 1d — skip path uses the repo-standard skip message
    if echo "${FUNC_BODY}" | grep -q "(already configured, skipping)"; then
        pass "${func} — logs '(already configured, skipping)' on the skip path"
    else
        fail "${func} — missing '(already configured, skipping)' skip message"
    fi

    # 1e — the old misleading update message must be gone
    if echo "${FUNC_BODY}" | grep -q "Updating existing configuration"; then
        fail "${func} — still logs 'Updating existing configuration' (no update path may exist)"
    else
        pass "${func} — no 'Updating existing configuration' message"
    fi

    # 1f — verification failure must abort with a clear error, not fall
    # through to POST (a transient outage would recreate issue #29 duplicates)
    if echo "${FUNC_BODY}" | grep -q "Could not verify existing"; then
        pass "${func} — verification failure aborts with 'Could not verify existing ...'"
    else
        fail "${func} — missing 'Could not verify existing ...' abort on GET failure"
    fi

    # 1g — the existence-check GET must not swallow failures with '|| true'
    if echo "${FUNC_BODY}" | grep -E "api/v1/settings/${svc}" | grep -q "|| true"; then
        fail "${func} — existence-check GET still swallows failures with '|| true'"
    else
        pass "${func} — existence-check GET does not swallow failures with '|| true'"
    fi
done

printf "\n"
info "Shared helper and id-extraction pipeline"

# 1h — shared helper: one edit site for the existence check (4 copies drifted
# once already in this PR — sh messages updated, ps1 not)
HELPER_BODY=$(extract_sh_function "check_overseerr_service")
if [[ -n "${HELPER_BODY}" ]]; then
    pass "check_overseerr_service() helper is defined"
else
    fail "check_overseerr_service() helper is not defined"
fi

if [[ $(grep -c "check_overseerr_service " "${CONFIGURE_SH}") -ge 2 ]]; then
    pass "check_overseerr_service is called by both Radarr and Sonarr wiring functions"
else
    fail "check_overseerr_service must be called by both Radarr and Sonarr wiring functions"
fi

# 1i — the helper must check the HTTP status code, not grep a raw body
if echo "${HELPER_BODY}" | grep -q "%{http_code}"; then
    pass "check_overseerr_service — captures %{http_code} (status-aware, not body-grep)"
else
    fail "check_overseerr_service — must capture %{http_code} to distinguish errors from data"
fi

# 1j — the fragile id-extraction pipeline must be gone: under set -e a
# terminal "grep -o '[0-9]*'" that matches nothing exits 1 and silently
# kills the whole script mid-configuration.
if grep -q "grep -o '\[0-9\]\*'" "${CONFIGURE_SH}"; then
    fail "configure.sh — fragile terminal \"grep -o '[0-9]*'\" pipeline still present (set -e abort risk)"
else
    pass "configure.sh — no fragile terminal \"grep -o '[0-9]*'\" id-extraction pipeline"
fi

# =============================================================================
# Phase 2: Indexer error reporting (configure.sh + configure.ps1)
# =============================================================================

section "Phase 2: Indexer error reporting"

printf "\n"
info "add_indexer — real HTTP failures must not be mislabeled as duplicates"

FUNC_BODY=$(extract_sh_function "add_indexer")

# 2a — the caller (add_public_indexers) already grep-skips genuine duplicates
# before calling add_indexer, so the failure branch is reached almost
# exclusively by real errors (400/401/500). It must report the status.
if echo "${FUNC_BODY}" | grep -q "may already exist"; then
    fail "add_indexer — still reports every failure as 'may already exist'"
else
    pass "add_indexer — no blanket 'may already exist' failure message"
fi

if echo "${FUNC_BODY}" | grep -q "%{http_code}"; then
    pass "add_indexer — captures %{http_code} from the POST"
else
    fail "add_indexer — must capture %{http_code} to report the real failure"
fi

if echo "${FUNC_BODY}" | grep -q "Failed to add .*HTTP"; then
    pass "add_indexer — failure message includes the HTTP status"
else
    fail "add_indexer — failure message must include the HTTP status"
fi

printf "\n"
info "Add-ProwlarrIndexer (configure.ps1) — same honest failure reporting"

PS1_FUNC=$(extract_ps1_function "Add-ProwlarrIndexer")

if echo "${PS1_FUNC}" | grep -q "may already exist"; then
    fail "Add-ProwlarrIndexer — still reports every failure as 'may already exist'"
else
    pass "Add-ProwlarrIndexer — no blanket 'may already exist' failure message"
fi

if echo "${PS1_FUNC}" | grep -q "Failed to add .*HTTP"; then
    pass "Add-ProwlarrIndexer — failure message includes the HTTP status"
else
    fail "Add-ProwlarrIndexer — failure message must include the HTTP status"
fi

# =============================================================================
# Phase 3: configure.ps1 Windows PowerShell 5.1 correctness
# =============================================================================

section "Phase 3: configure.ps1 Windows PowerShell 5.1 correctness"

printf "\n"
info "Encoding — BOM guard for powershell.exe 5.1 (reads BOM-less files as ANSI)"

# 3a — configure.ps1 contains multi-byte glyphs (✓/✗, box-drawing, 🎉);
# without a UTF-8 BOM Windows PowerShell 5.1 renders them as mojibake.
BOM=$(head -c 3 "${CONFIGURE_PS1}" | od -An -tx1 | tr -d ' \n')
if [[ "${BOM}" == "efbbbf" ]]; then
    pass "configure.ps1 — starts with a UTF-8 BOM (ef bb bf)"
else
    fail "configure.ps1 — missing UTF-8 BOM (got: ${BOM:-empty}) — PS 5.1 mojibake"
fi

printf "\n"
info "Overseerr wiring functions — PS 5.1-safe existence check"

for func in Add-RadarrToOverseerr Add-SonarrToOverseerr; do
    PS1_FUNC=$(extract_ps1_function "${func}")

    # 3b — .Count on a raw Invoke-RestMethod result is a PS 5.1 landmine:
    # a single-element JSON array unwraps to a scalar PSCustomObject with no
    # intrinsic .Count until PowerShell 6.1, so the check silently fails and
    # the function POSTs a duplicate on every re-run.
    # shellcheck disable=SC2016  # reason: literal PowerShell '$existing' pattern
    if echo "${PS1_FUNC}" | grep -q '\$existing\.Count'; then
        fail "${func} — still calls .Count on raw \$existing (PS 5.1 scalar unwrap bug)"
    else
        pass "${func} — no .Count on raw \$existing"
    fi

    # 3c — SilentlyContinue cannot suppress Invoke-RestMethod's
    # statement-terminating HTTP errors; the GET must own its failure path.
    if echo "${PS1_FUNC}" | grep -q "SilentlyContinue"; then
        fail "${func} — still uses -ErrorAction SilentlyContinue (no-op for terminating errors)"
    else
        pass "${func} — no -ErrorAction SilentlyContinue"
    fi

    # 3d — no PUT upsert (parity with Phase 1a)
    if echo "${PS1_FUNC}" | grep -q -- "-Method Put"; then
        fail "${func} — still PUTs to Overseerr settings"
    else
        pass "${func} — no PUT to Overseerr settings"
    fi
done

printf "\n"
info "Shared helper — Test-OverseerrServiceConfigured"

PS1_HELPER=$(extract_ps1_function "Test-OverseerrServiceConfigured")
if [[ -n "${PS1_HELPER}" ]]; then
    pass "Test-OverseerrServiceConfigured helper is defined"
else
    fail "Test-OverseerrServiceConfigured helper is not defined"
fi

# The helper must array-wrap the Invoke-RestMethod result before filtering
# shellcheck disable=SC2016  # reason: literal PowerShell '$existing' pattern
if echo "${PS1_HELPER}" | grep -q '@(\$existing)'; then
    pass "Test-OverseerrServiceConfigured — array-wraps \$existing with @() (PS 5.1 safe)"
else
    fail "Test-OverseerrServiceConfigured — must array-wrap \$existing with @()"
fi

if [[ $(grep -c "Test-OverseerrServiceConfigured " "${CONFIGURE_PS1}") -ge 2 ]]; then
    pass "Test-OverseerrServiceConfigured is called by both wiring functions"
else
    fail "Test-OverseerrServiceConfigured must be called by both wiring functions"
fi

# =============================================================================
# Phase 4: configure.sh / configure.ps1 message parity
# =============================================================================

section "Phase 4: Message parity (repo rule: same user feedback in both scripts)"

printf "\n"
info "Identical user-facing strings must exist in BOTH configure.sh and configure.ps1"

check_parity_string() {
    local label=$1
    local needle=$2
    local in_sh=false in_ps1=false
    grep -qF "${needle}" "${CONFIGURE_SH}" && in_sh=true
    grep -qF "${needle}" "${CONFIGURE_PS1}" && in_ps1=true
    if [[ "${in_sh}" == "true" && "${in_ps1}" == "true" ]]; then
        pass "${label} — present in both scripts"
    else
        fail "${label} — sh:${in_sh} ps1:${in_ps1} (must be in both)"
    fi
}

check_parity_string "success: 'Radarr added to Overseerr'" "Radarr added to Overseerr"
check_parity_string "success: 'Sonarr added to Overseerr'" "Sonarr added to Overseerr"
check_parity_string "failure: 'Failed to add Radarr to Overseerr'" "Failed to add Radarr to Overseerr"
check_parity_string "failure: 'Failed to add Sonarr to Overseerr'" "Failed to add Sonarr to Overseerr"
check_parity_string "skip: 'Radarr already configured in Overseerr (already configured, skipping)'" \
    "Radarr already configured in Overseerr (already configured, skipping)"
check_parity_string "skip: 'Sonarr already configured in Overseerr (already configured, skipping)'" \
    "Sonarr already configured in Overseerr (already configured, skipping)"
check_parity_string "verify-abort: 'Could not verify existing Radarr configuration in Overseerr'" \
    "Could not verify existing Radarr configuration in Overseerr"
check_parity_string "verify-abort: 'Could not verify existing Sonarr configuration in Overseerr'" \
    "Could not verify existing Sonarr configuration in Overseerr"
check_parity_string "indexer failure prefix: 'Failed to add'" "Failed to add"

# The old divergent strings must be gone from both scripts
for stale in "Radarr configured in Overseerr" "Sonarr configured in Overseerr" \
    "Failed to configure Radarr in Overseerr" "Failed to configure Sonarr in Overseerr" \
    "Could not add Radarr to Overseerr" "Could not add Sonarr to Overseerr"; do
    if grep -qF "${stale}" "${CONFIGURE_SH}" || grep -qF "${stale}" "${CONFIGURE_PS1}"; then
        fail "stale message still present: '${stale}'"
    else
        pass "stale message removed: '${stale}'"
    fi
done

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
    printf "  %bAll tests passed.%b\n\n" "${GREEN}${BOLD}" "${NC}"
    exit 0
else
    printf "  %b%d test(s) failed.%b\n\n" "${RED}${BOLD}" "${FAIL_COUNT}" "${NC}"
    exit 1
fi
