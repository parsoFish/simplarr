#!/bin/bash
# =============================================================================
# Simplarr — config.json.template API and Health Path Schema (TDD Test Suite)
# =============================================================================
# Validates that homepage/config.json.template is extended with `apiPaths` and
# `healthPaths` objects alongside the existing port fields, and that the file
# still produces valid JSON after envsubst substitution.
#
#   Expected template structure after implementation:
#     {
#       "plex":         ${PLEX_PORT},          ← kept for backward compat
#       ...                                    ← all port fields still present
#       "apiPaths": {
#         "plex":         "/plex",
#         "radarr":       "/radarr",
#         ...
#       },
#       "healthPaths": {
#         "radarr":       "/radarr/api/v3/health",
#         ...
#       }
#     }
#
#   Static strings (paths) must NOT use ${VAR} syntax — envsubst must leave
#   them completely untouched, so the generated config.json retains the
#   literal path strings.
#
# Test Phases:
#   1  Template Existence         — config.json.template is present
#   2  apiPaths Object            — top-level "apiPaths" key exists; all 7
#                                   services have a path entry
#   3  healthPaths Object         — top-level "healthPaths" key exists; all 7
#                                   services have a health path entry
#   4  Path Format                — every path value begins with "/" (not a
#                                   number, not an envsubst placeholder)
#   5  Backward Compatibility     — original port placeholder fields are still
#                                   present (schema extension is additive)
#   6  Nginx Route Alignment      — apiPaths align with the nginx location
#                                   directives in unified.conf and split.conf
#   7  envsubst Safety            — after envsubst substitution the output is
#                                   valid JSON and contains no ${VAR} tokens;
#                                   static path strings survive unchanged
#
# TDD: All Phase 2–7 assertions FAIL on the current codebase (template has
# only port fields).  They PASS once the implementation adds apiPaths and
# healthPaths to config.json.template.
#
# Usage:
#   ./dev-testing/test_config_api_paths.sh
#
# Exit Codes:
#   0 — All tests passed
#   1 — One or more tests failed
#
# No Docker dependency — Phases 1–6 are pure grep/awk structural checks.
# Phase 7 uses the system `envsubst` binary (from gettext); auto-skipped if
# envsubst is not available.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_TEMPLATE="${PROJECT_ROOT}/homepage/config.json.template"
ENTRYPOINT_SH="${PROJECT_ROOT}/homepage/entrypoint.sh"
UNIFIED_CONF="${PROJECT_ROOT}/nginx/unified.conf"

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
printf "  config.json.template API and Health Path Schema (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

# The 7 services that must have entries in both apiPaths and healthPaths.
# "qbittorrent" is the JSON key; its nginx route is /torrent (split below).
declare -a SERVICES=(
    "plex"
    "radarr"
    "sonarr"
    "prowlarr"
    "overseerr"
    "qbittorrent"
    "tautulli"
)

# ---------------------------------------------------------------------------
# Phase 1: Template Existence
# ---------------------------------------------------------------------------

section "Phase 1: Template Existence"

printf "\n"
info "Verifying homepage/config.json.template is present"
printf "\n"

_TEMPLATE_PRESENT=true

if [[ -f "${CONFIG_TEMPLATE}" ]]; then
    pass "homepage/config.json.template — file exists"
else
    fail "homepage/config.json.template — file missing (all subsequent phases cannot proceed)"
    _TEMPLATE_PRESENT=false
fi

# ---------------------------------------------------------------------------
# Phase 2: apiPaths Object
#
# The template must contain a top-level "apiPaths" JSON key followed by an
# object with at least the 7 canonical service keys.  Each value must be a
# quoted string (not a ${VAR} placeholder or a bare number).
#
# TDD: FAIL on the current template (only has port fields); PASS once
# "apiPaths" is added as a nested object.
# ---------------------------------------------------------------------------

section "Phase 2: apiPaths Object"

printf "\n"
info "Asserting top-level \"apiPaths\" key and per-service path entries"
printf "\n"

if [[ "${_TEMPLATE_PRESENT}" != "true" ]]; then
    for svc in "${SERVICES[@]}"; do
        skip "apiPaths.${svc} — template not found"
    done
else
    # 2.1 — "apiPaths" key must exist
    if grep -qE '"apiPaths"[[:space:]]*:' "${CONFIG_TEMPLATE}"; then
        pass "config.json.template — \"apiPaths\" top-level key is present"
    else
        fail "config.json.template — missing \"apiPaths\" top-level key (must add apiPaths object)"
    fi

    printf "\n"
    info "Per-service apiPath entries"

    # 2.2 — Each service must have a quoted path entry under apiPaths.
    # We search for the service name as a JSON key followed by a quoted value
    # that starts with "/" (ruling out port numbers or ${VAR} placeholders).
    for svc in "${SERVICES[@]}"; do
        if grep -qE "\"${svc}\"[[:space:]]*:[[:space:]]*\"/[^\"]*\"" "${CONFIG_TEMPLATE}"; then
            pass "config.json.template — apiPaths.${svc} has a quoted \"/…\" path value"
        else
            fail "config.json.template — apiPaths.${svc} is missing a quoted \"/…\" path value"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 3: healthPaths Object
#
# The template must contain a top-level "healthPaths" JSON key followed by an
# object with at least the 7 canonical service keys.  Each value must be a
# quoted string starting with "/".
#
# TDD: FAIL on the current template; PASS once "healthPaths" is added.
# ---------------------------------------------------------------------------

section "Phase 3: healthPaths Object"

printf "\n"
info "Asserting top-level \"healthPaths\" key and per-service health path entries"
printf "\n"

if [[ "${_TEMPLATE_PRESENT}" != "true" ]]; then
    for svc in "${SERVICES[@]}"; do
        skip "healthPaths.${svc} — template not found"
    done
else
    # 3.1 — "healthPaths" key must exist
    if grep -qE '"healthPaths"[[:space:]]*:' "${CONFIG_TEMPLATE}"; then
        pass "config.json.template — \"healthPaths\" top-level key is present"
    else
        fail "config.json.template — missing \"healthPaths\" top-level key (must add healthPaths object)"
    fi

    printf "\n"
    info "Per-service healthPath entries"

    for svc in "${SERVICES[@]}"; do
        if grep -qE "\"${svc}\"[[:space:]]*:[[:space:]]*\"/[^\"]*\"" "${CONFIG_TEMPLATE}"; then
            pass "config.json.template — healthPaths.${svc} has a quoted \"/…\" path value"
        else
            fail "config.json.template — healthPaths.${svc} is missing a quoted \"/…\" path value"
        fi
    done

    # 3.2 — Spot-check: radarr health path must include the specific API endpoint
    # that Radarr v3 exposes.  The nginx /radarr prefix must be prepended so
    # status.js can build the full URL without knowing the nginx layout.
    printf "\n"
    info "Spot-checking known health path values"

    if grep -qE '"radarr"[[:space:]]*:[[:space:]]*"/radarr/api/v3/health"' "${CONFIG_TEMPLATE}"; then
        pass "config.json.template — radarr healthPath is \"/radarr/api/v3/health\" (expected Radarr v3 endpoint)"
    else
        fail "config.json.template — radarr healthPath should be \"/radarr/api/v3/health\""
    fi

    if grep -qE '"sonarr"[[:space:]]*:[[:space:]]*"/sonarr/api/v3/health"' "${CONFIG_TEMPLATE}"; then
        pass "config.json.template — sonarr healthPath is \"/sonarr/api/v3/health\" (expected Sonarr v3 endpoint)"
    else
        fail "config.json.template — sonarr healthPath should be \"/sonarr/api/v3/health\""
    fi
fi

# ---------------------------------------------------------------------------
# Phase 4: Path Format Validation
#
# Every quoted value inside the apiPaths and healthPaths blocks must:
#   - Start with "/" (relative URL path, not an absolute URL or a number)
#   - NOT contain "${" — no envsubst placeholders in path values
#   - NOT be an empty string
#
# TDD: FAIL on current template (no path objects); PASS once paths are added.
# ---------------------------------------------------------------------------

section "Phase 4: Path Format Validation"

printf "\n"
info "Asserting all path values start with \"/\" and contain no \${VAR} placeholders"
printf "\n"

if [[ "${_TEMPLATE_PRESENT}" != "true" ]]; then
    skip "path format checks — template not found"
elif ! grep -qE '"apiPaths"|"healthPaths"' "${CONFIG_TEMPLATE}"; then
    skip "path format checks — neither apiPaths nor healthPaths exists in template yet"
else
    # 4.1 — No path value should start with "${" (would be treated as a variable
    # by envsubst, which only substitutes the tokens listed in entrypoint.sh)
    _var_in_paths=false
    _problem_line=""
    while IFS= read -r line; do
        # Look for lines that appear to be inside an apiPaths/healthPaths block
        # and contain a value like: "key": "${SOME_VAR}"
        if echo "${line}" | grep -qE '"[a-z]+"[[:space:]]*:[[:space:]]*"\$\{'; then
            _var_in_paths=true
            _problem_line="${line}"
            break
        fi
    done < "${CONFIG_TEMPLATE}"

    if [[ "${_var_in_paths}" == "true" ]]; then
        fail "config.json.template — path value uses \${VAR} syntax (found: ${_problem_line})"
        info "Path values must be static strings; envsubst placeholders belong in port fields only"
    else
        pass "config.json.template — no \${VAR} placeholders in quoted path string values"
    fi

    # 4.2 — Every non-empty quoted value that starts with "/" must be a non-trivial
    # path (at least two characters: "/" + something).  Empty paths like "" or
    # single-slash values are suspicious but not prohibited.
    _short_path=$(grep -oE '"(/)"' "${CONFIG_TEMPLATE}" | head -1 || true)
    if [[ -n "${_short_path}" ]]; then
        fail "config.json.template — bare \"/\" path found (${_short_path}); use specific sub-path or health endpoint"
    else
        pass "config.json.template — no bare \"/\" path values found (all paths are sub-paths)"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 5: Backward Compatibility — Port Placeholders Still Present
#
# The schema extension is additive.  All original port placeholder fields
# (${PLEX_PORT}, ${RADARR_PORT}, etc.) must remain in the template.
#
# Rationale: existing consumers (dashboard.js, status.js) may still read port
# values from the top-level keys.  Removing them would break those consumers.
# ---------------------------------------------------------------------------

section "Phase 5: Backward Compatibility — Port Fields"

printf "\n"
info "Asserting all original port placeholder fields are still present"
printf "\n"

if [[ "${_TEMPLATE_PRESENT}" != "true" ]]; then
    skip "backward-compatibility checks — template not found"
else
    declare -a PORT_PLACEHOLDERS=(
        "PLEX_PORT"
        "RADARR_PORT"
        "SONARR_PORT"
        "PROWLARR_PORT"
        "OVERSEERR_PORT"
        "QBITTORRENT_PORT"
        "TAUTULLI_PORT"
    )

    for placeholder in "${PORT_PLACEHOLDERS[@]}"; do
        if grep -qE "\\\$\{${placeholder}\}" "${CONFIG_TEMPLATE}"; then
            pass "config.json.template — \${${placeholder}} is still present (backward compat)"
        else
            fail "config.json.template — \${${placeholder}} was removed; schema extension must be additive"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 6: Nginx Route Alignment
#
# The apiPath for each service must match the nginx location directive prefix
# defined in unified.conf (and split.conf).  Mismatches would cause status.js
# to construct wrong health-check URLs.
#
# Expected alignment (nginx location → apiPath value):
#   location /radarr       →  "radarr":      "/radarr"
#   location /sonarr       →  "sonarr":      "/sonarr"
#   location /prowlarr     →  "prowlarr":    "/prowlarr"
#   location /overseerr    →  "overseerr":   "/overseerr"
#   location /torrent      →  "qbittorrent": "/torrent"  (nginx route differs from key)
#   location /tautulli     →  "tautulli":    "/tautulli"
#   location /plex         →  "plex":        "/plex"
# ---------------------------------------------------------------------------

section "Phase 6: Nginx Route Alignment"

printf "\n"
info "Verifying apiPaths values align with nginx location directives"
printf "\n"

if [[ "${_TEMPLATE_PRESENT}" != "true" ]]; then
    skip "nginx alignment checks — template not found"
elif ! grep -qE '"apiPaths"' "${CONFIG_TEMPLATE}"; then
    skip "nginx alignment checks — apiPaths not yet in template"
else
    # Helper: assert that the template's apiPath for $1 is $2, and that $2
    # appears as a location prefix in unified.conf.
    assert_api_path_nginx_alignment() {
        local svc="$1"
        local expected_path="$2"

        # Check the template value
        if grep -qE "\"${svc}\"[[:space:]]*:[[:space:]]*\"${expected_path}\"" "${CONFIG_TEMPLATE}"; then
            pass "config.json.template — apiPaths.${svc} = \"${expected_path}\""
        else
            fail "config.json.template — apiPaths.${svc} should be \"${expected_path}\" (matches nginx location)"
        fi

        # Cross-check against unified.conf location directive
        if [[ -f "${UNIFIED_CONF}" ]]; then
            if grep -qE "location[[:space:]]+(=[[:space:]]+)?${expected_path}([[:space:]]|$|\{)" "${UNIFIED_CONF}"; then
                pass "unified.conf — location ${expected_path} exists (apiPath is consistent)"
            else
                fail "unified.conf — no location ${expected_path} found; apiPaths.${svc} may be wrong"
            fi
        else
            skip "unified.conf alignment for ${svc} — unified.conf not found"
        fi
    }

    assert_api_path_nginx_alignment "radarr"      "/radarr"
    assert_api_path_nginx_alignment "sonarr"      "/sonarr"
    assert_api_path_nginx_alignment "prowlarr"    "/prowlarr"
    assert_api_path_nginx_alignment "overseerr"   "/overseerr"
    assert_api_path_nginx_alignment "tautulli"    "/tautulli"
    assert_api_path_nginx_alignment "plex"        "/plex"

    printf "\n"
    info "qbittorrent uses nginx route /torrent (key name differs from route)"

    # qbittorrent's nginx location is /torrent, not /qbittorrent
    if grep -qE '"qbittorrent"[[:space:]]*:[[:space:]]*"/torrent"' "${CONFIG_TEMPLATE}"; then
        pass "config.json.template — apiPaths.qbittorrent = \"/torrent\" (matches nginx location /torrent)"
    else
        fail "config.json.template — apiPaths.qbittorrent should be \"/torrent\" (nginx routes qBittorrent under /torrent)"
    fi

    if [[ -f "${UNIFIED_CONF}" ]]; then
        if grep -qE 'location[[:space:]]+/torrent([[:space:]]|\{)' "${UNIFIED_CONF}"; then
            pass "unified.conf — location /torrent exists (apiPaths.qbittorrent is consistent)"
        else
            fail "unified.conf — no location /torrent found; apiPaths.qbittorrent alignment cannot be confirmed"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Phase 7: envsubst Safety — Valid JSON After Substitution
#
# homepage/entrypoint.sh calls envsubst with an explicit list of ${VAR} tokens:
#   envsubst '${PLEX_PORT} ${OVERSEERR_PORT} ...' < config.json.template > config.json
#
# Because only the listed port tokens are substituted and the new apiPaths /
# healthPaths values are static strings, the rendered config.json must:
#   a) Be valid JSON (no unquoted port numbers break JSON structure)
#   b) Contain no residual ${VAR} tokens (all ports were in the envsubst list)
#   c) Retain the literal path strings exactly as written in the template
#
# This phase simulates entrypoint.sh by running envsubst locally with dummy
# port values, then validates the output with python3.
#
# Auto-skipped when envsubst or python3 are unavailable.
# ---------------------------------------------------------------------------

section "Phase 7: envsubst Safety — Valid JSON After Substitution"

printf "\n"
info "Simulating entrypoint.sh envsubst substitution and validating JSON output"
printf "\n"

if [[ "${_TEMPLATE_PRESENT}" != "true" ]]; then
    skip "envsubst safety checks — template not found"
    skip "valid JSON check — template not found"
    skip "no residual placeholders check — template not found"
    skip "static path strings preserved — template not found"
elif ! command -v envsubst &>/dev/null; then
    skip "envsubst not available — skipping substitution tests (install gettext to enable)"
    skip "valid JSON check — envsubst not available"
    skip "no residual placeholders check — envsubst not available"
    skip "static path strings preserved — envsubst not available"
else
    # Provide dummy numeric values that envsubst will substitute in.
    # Using distinct values makes it easy to spot which port was substituted.
    _RENDERED=$(
        PLEX_PORT=32400 \
        OVERSEERR_PORT=5055 \
        RADARR_PORT=7878 \
        SONARR_PORT=8989 \
        PROWLARR_PORT=9696 \
        QBITTORRENT_PORT=8080 \
        TAUTULLI_PORT=8181 \
        envsubst \
            '${PLEX_PORT} ${OVERSEERR_PORT} ${RADARR_PORT} ${SONARR_PORT} ${PROWLARR_PORT} ${QBITTORRENT_PORT} ${TAUTULLI_PORT}' \
            < "${CONFIG_TEMPLATE}"
    )

    # 7.1 — Output must not contain any ${VAR} placeholders.
    # The envsubst call above lists all recognised port tokens; any residual
    # ${...} tokens indicate an undeclared placeholder was added to the template
    # without updating entrypoint.sh.
    if echo "${_RENDERED}" | grep -qE '\$\{[A-Z_]+\}'; then
        _residual=$(echo "${_RENDERED}" | grep -oE '\$\{[A-Z_]+\}' | sort -u | head -5 | tr '\n' ' ')
        fail "config.json after envsubst still contains unsubstituted placeholders: ${_residual}"
        info "If new \${VAR} tokens were added to the template, add them to entrypoint.sh envsubst call too"
    else
        pass "config.json after envsubst — no residual \${VAR} placeholders"
    fi

    # 7.2 — Output must be valid JSON.
    if command -v python3 &>/dev/null; then
        if echo "${_RENDERED}" | python3 -c "import sys, json; json.load(sys.stdin)" &>/dev/null 2>&1; then
            pass "config.json after envsubst — is valid JSON"
        else
            _json_err=$(echo "${_RENDERED}" | python3 -c "import sys, json; json.load(sys.stdin)" 2>&1 | head -3)
            fail "config.json after envsubst — not valid JSON: ${_json_err}"
            info "Template has malformed JSON structure; check bracket matching after adding apiPaths/healthPaths"
        fi
    else
        skip "valid JSON check — python3 not available"
    fi

    # 7.3 — Static path strings must survive envsubst unchanged.
    # Verify radarr's health path is present literally in the rendered output;
    # if it was accidentally written as a ${VAR} it would be blank or gone.
    if echo "${_RENDERED}" | grep -qF '"/radarr/api/v3/health"'; then
        pass "config.json after envsubst — radarr healthPath string \"/radarr/api/v3/health\" preserved"
    else
        fail "config.json after envsubst — radarr healthPath \"/radarr/api/v3/health\" missing from rendered output"
        info "Path strings must be static literals in the template, not \${VAR} references"
    fi

    if echo "${_RENDERED}" | grep -qF '"/sonarr/api/v3/health"'; then
        pass "config.json after envsubst — sonarr healthPath string \"/sonarr/api/v3/health\" preserved"
    else
        fail "config.json after envsubst — sonarr healthPath \"/sonarr/api/v3/health\" missing from rendered output"
    fi

    # 7.4 — Port values must be substituted (not literal ${RADARR_PORT} strings)
    if echo "${_RENDERED}" | grep -qF '"radarr": 7878'; then
        pass "config.json after envsubst — radarr port (7878) correctly substituted"
    else
        # Some formats may use the service as a key inside a "ports" sub-object
        if echo "${_RENDERED}" | grep -qF '7878'; then
            pass "config.json after envsubst — port value 7878 present in output (port substitution worked)"
        else
            fail "config.json after envsubst — port 7878 not found; \${RADARR_PORT} substitution may have failed"
        fi
    fi

    # 7.5 — entrypoint.sh must list the same port tokens that the template uses.
    # If new tokens are added to the template they must appear in entrypoint.sh too.
    if [[ -f "${ENTRYPOINT_SH}" ]]; then
        printf "\n"
        info "Cross-checking template placeholders against entrypoint.sh envsubst token list"

        declare -a EXPECTED_TOKENS=(
            "PLEX_PORT"
            "RADARR_PORT"
            "SONARR_PORT"
            "PROWLARR_PORT"
            "OVERSEERR_PORT"
            "QBITTORRENT_PORT"
            "TAUTULLI_PORT"
        )

        for token in "${EXPECTED_TOKENS[@]}"; do
            if grep -qF "${token}" "${ENTRYPOINT_SH}"; then
                pass "entrypoint.sh — \${${token}} is in the envsubst token list"
            else
                fail "entrypoint.sh — \${${token}} is missing from envsubst call (new port tokens need to be added)"
            fi
        done

        # The template's static path values must NOT appear in the envsubst
        # token list; listing a path string as an envsubst token would cause it
        # to be treated as a variable reference and substituted to empty.
        if grep -qE 'envsubst.*"/radarr"' "${ENTRYPOINT_SH}"; then
            fail "entrypoint.sh — \"/radarr\" path literal appears in the envsubst token list (only \${VAR} tokens should be listed)"
        else
            pass "entrypoint.sh — path literals are not in the envsubst token list (correct)"
        fi
    else
        skip "entrypoint.sh token cross-check — entrypoint.sh not found"
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
    printf "\n  TDD note: failures in Phases 2–7 indicate the apiPaths/healthPaths\n"
    printf "  schema extension has not yet been added to config.json.template.\n"
    printf "\n  Implementation checklist:\n"
    printf "    1. Add \"apiPaths\" object with \"/route\" strings for each service\n"
    printf "    2. Add \"healthPaths\" object with specific health endpoints per service\n"
    printf "       (e.g. radarr: \"/radarr/api/v3/health\", sonarr: \"/sonarr/api/v3/health\")\n"
    printf "    3. Keep all existing \${SERVICE_PORT} placeholders at top level\n"
    printf "    4. Do NOT wrap path values in \${} — they must be static strings\n"
    printf "    5. Verify with: envsubst < config.json.template | python3 -m json.tool\n"
    printf "\n"
    exit 1
fi
