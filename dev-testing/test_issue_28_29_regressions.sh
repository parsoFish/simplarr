#!/bin/bash
# =============================================================================
# Issue #28 / #29 Regression Tests
# =============================================================================
# Guards the root causes reproduced on 2026-08-14:
#
#   #28 — nginx crash-looped on native Linux Docker with
#         'host not found in upstream "host.docker.internal"' (unified.conf:48,
#         the Plex health-check upstream). Docker Desktop resolves the name;
#         native Linux needs extra_hosts: host-gateway on the nginx service.
#         The /plex redirect must also send the *browser* to a resolvable
#         host ($host), never host.docker.internal.
#
#   #29 — configure.sh exited non-zero as soon as Overseerr was initialized:
#         overseerr_api_key=$(get_overseerr_api_key) was unguarded under
#         set -e, and get_overseerr_api_key failed two independent ways
#         (raw $DOCKER_CONFIG path; compact-JSON grep vs Overseerr's
#         pretty-printed settings.json). Unguarded main-level integration
#         steps also aborted the script before the Prowlarr indexers ran.
#
# Phases:
#   1  Static #28  — extra_hosts present, /plex redirect uses $host
#   2  Docker #28  — nginx config parse with blackholed external DNS fails
#                    without the host mapping and passes with it
#                    (skipped when docker is unavailable)
#   3  Unit #29    — get_overseerr_api_key handles pretty-printed and
#                    compact settings.json, honours CONFIG_DIR/DOCKER_CONFIG
#   4  Static #29  — set -e guards present; dead TorrentGalaxy indexer gone
#
# Usage:
#   ./dev-testing/test_issue_28_29_regressions.sh
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
UNIFIED_COMPOSE="${PROJECT_ROOT}/docker-compose-unified.yml"
UNIFIED_CONF="${PROJECT_ROOT}/nginx/unified.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { printf "  %b[PASS]%b %s\n" "${GREEN}" "${NC}" "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf "  %b[FAIL]%b %s\n" "${RED}" "${NC}" "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { printf "  %b[SKIP]%b %s\n" "${YELLOW}" "${NC}" "$1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

section() {
    printf "\n%b%s%b\n%b%s%b\n" \
        "${BOLD}${CYAN}" "$1" "${NC}" \
        "${CYAN}" "────────────────────────────────────────────────────────────" "${NC}"
}

# Extract a function body from configure.sh (funcname() … first } at column 0).
extract_sh_function() {
    local func_name=$1
    awk "/^${func_name}\(\)/,/^\}/" "${CONFIGURE_SH}"
}

_TMPDIR="$(mktemp -d)"
# shellcheck disable=SC2317  # reason: called indirectly via EXIT trap
cleanup() {
    rm -rf "${_TMPDIR}"
    if [[ "${_DOCKER_NET_CREATED:-false}" == "true" ]]; then
        docker rm -f issue2829-alias-stub >/dev/null 2>&1 || true
        docker network rm issue2829-net >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Phase 1: Static #28 — compose and nginx conf
# ---------------------------------------------------------------------------
section "Phase 1: #28 static — extra_hosts + /plex redirect"

# 1a — nginx service must map host.docker.internal to the host gateway
if awk '/^  nginx:/{f=1; next} f && /^  [a-z]/{f=0} f' "${UNIFIED_COMPOSE}" | \
        grep -q 'host.docker.internal:host-gateway'; then
    pass "docker-compose-unified.yml — nginx has extra_hosts host.docker.internal:host-gateway"
else
    fail "docker-compose-unified.yml — nginx is missing extra_hosts 'host.docker.internal:host-gateway' (issue #28: nginx crash-loops on native Linux Docker)"
fi

# 1b — the /plex redirect must use a browser-resolvable host
if grep -q 'return 302 https://host\.docker\.internal' "${UNIFIED_CONF}"; then
    fail "nginx/unified.conf — /plex redirect still sends the browser to host.docker.internal (unresolvable from LAN clients)"
else
    pass "nginx/unified.conf — /plex redirect no longer targets host.docker.internal"
fi
if grep -q 'return 302 https://\$host:32400/web' "${UNIFIED_CONF}"; then
    pass "nginx/unified.conf — /plex redirect uses \$host"
else
    fail "nginx/unified.conf — /plex redirect must use \$host so the browser can resolve it"
fi

# ---------------------------------------------------------------------------
# Phase 2: Docker #28 — nginx config parse under native-Linux DNS conditions
# ---------------------------------------------------------------------------
section "Phase 2: #28 docker — config parse with blackholed external DNS"

NGINX_IMAGE="$(awk '/^  nginx:/{f=1; next} f && /^  [a-z]/{f=0} f' "${UNIFIED_COMPOSE}" | \
    grep -m1 'image:' | awk '{print $2}')"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "docker unavailable — skipping live nginx config-parse checks"
else
    _DOCKER_NET_CREATED=true
    docker network create issue2829-net >/dev/null 2>&1 || true
    # One stub answering for every upstream DNS name nginx references.
    docker run -d --name issue2829-alias-stub --network issue2829-net \
        --network-alias homepage --network-alias radarr --network-alias sonarr \
        --network-alias prowlarr --network-alias overseerr \
        --network-alias qbittorrent --network-alias tautulli \
        alpine sleep 300 >/dev/null 2>&1 || true

    # Substitute the SUBDOMAIN_TLD placeholder the way setup.sh does.
    sed 's/SUBDOMAIN_TLD/local/g' "${UNIFIED_CONF}" > "${_TMPDIR}/default.conf"

    # 2a — WITHOUT the host mapping, blackholed DNS must reproduce the
    #      issue-#28 failure (guards the repro itself: if this ever passes,
    #      the conf no longer depends on host.docker.internal at parse time
    #      and the extra_hosts requirement can be revisited).
    if docker run --rm --network issue2829-net --dns 127.0.0.1 \
            -v "${_TMPDIR}/default.conf:/etc/nginx/conf.d/default.conf:ro" \
            "${NGINX_IMAGE}" nginx -t >/dev/null 2>&1; then
        skip "nginx -t passed without the host mapping — conf no longer references host.docker.internal at parse time?"
    else
        pass "nginx -t fails without host mapping under blackholed DNS (reproduces #28)"
    fi

    # 2b — WITH the mapping (what extra_hosts provides), the same conf must parse.
    if docker run --rm --network issue2829-net --dns 127.0.0.1 \
            --add-host host.docker.internal:host-gateway \
            -v "${_TMPDIR}/default.conf:/etc/nginx/conf.d/default.conf:ro" \
            "${NGINX_IMAGE}" nginx -t >/dev/null 2>&1; then
        pass "nginx -t passes with host.docker.internal:host-gateway mapping (#28 fixed)"
    else
        fail "nginx -t still fails with the host-gateway mapping — #28 fix is not effective"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: Unit #29 — get_overseerr_api_key
# ---------------------------------------------------------------------------
section "Phase 3: #29 unit — get_overseerr_api_key"

RESOLVE_DIR_FUNC="$(extract_sh_function "resolve_config_dir")"
GET_KEY_FUNC="$(extract_sh_function "get_overseerr_api_key")"

if [[ -z "${GET_KEY_FUNC}" ]]; then
    fail "get_overseerr_api_key() not found in configure.sh"
else
    # Fixture: pretty-printed settings.json exactly as Overseerr writes it
    # (1-space indent, space after the colon).
    mkdir -p "${_TMPDIR}/pretty/overseerr"
    cat > "${_TMPDIR}/pretty/overseerr/settings.json" << 'EOF'
{
 "clientId": "00000000-0000-0000-0000-000000000000",
 "main": {
  "apiKey": "pretty-printed-key==",
  "applicationTitle": "Overseerr"
 },
 "public": {
  "initialized": true
 }
}
EOF
    # Fixture: compact JSON (the only shape the old grep handled).
    mkdir -p "${_TMPDIR}/compact/overseerr"
    printf '{"main":{"apiKey":"compact-key=="},"public":{"initialized":true}}' \
        > "${_TMPDIR}/compact/overseerr/settings.json"

    run_get_key() {
        # $1: env assignments, e.g. 'CONFIG_DIR=/x' — deliberately word-split
        # shellcheck disable=SC2086
        env -i PATH="$PATH" $1 bash -c "
            log_info() { :; }; log_error() { :; }; log_success() { :; }
            ${RESOLVE_DIR_FUNC}
            ${GET_KEY_FUNC}
            get_overseerr_api_key
        " 2>/dev/null
    }

    # 3a — pretty-printed settings.json via CONFIG_DIR (issue #29 crash shape)
    if [[ "$(run_get_key "CONFIG_DIR=${_TMPDIR}/pretty")" == "pretty-printed-key==" ]]; then
        pass "extracts apiKey from pretty-printed settings.json via CONFIG_DIR"
    else
        fail "cannot extract apiKey from pretty-printed settings.json (issue #29: Overseerr pretty-prints, old pattern needed compact JSON)"
    fi

    # 3b — compact JSON must still work
    if [[ "$(run_get_key "CONFIG_DIR=${_TMPDIR}/compact")" == "compact-key==" ]]; then
        pass "extracts apiKey from compact settings.json"
    else
        fail "compact settings.json regressed"
    fi

    # 3c — DOCKER_CONFIG fallback (CONFIG_DIR unset)
    if [[ "$(run_get_key "DOCKER_CONFIG=${_TMPDIR}/pretty")" == "pretty-printed-key==" ]]; then
        pass "falls back to DOCKER_CONFIG when CONFIG_DIR is unset"
    else
        fail "DOCKER_CONFIG fallback broken in get_overseerr_api_key"
    fi

    # 3d — missing file must return 1, not exit the shell
    if run_get_key "CONFIG_DIR=${_TMPDIR}/nonexistent" >/dev/null; then
        fail "get_overseerr_api_key returned 0 for a missing settings.json"
    else
        pass "returns non-zero (without exiting) when settings.json is missing"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3b: Unit #29 round 2 — resolve_config_dir .env autoload
# ---------------------------------------------------------------------------
section "Phase 3b: #29 round 2 unit — resolve_config_dir .env autoload"

if [[ -z "${RESOLVE_DIR_FUNC}" ]]; then
    fail "resolve_config_dir() not found in configure.sh (issue #29 round 2: configure.sh must auto-load DOCKER_CONFIG from .env)"
else
    run_resolve_config_dir() {
        # $1: env assignments, e.g. 'SCRIPT_DIR=/x DOCKER_CONFIG=/y' —
        # deliberately word-split
        # shellcheck disable=SC2086
        env -i PATH="$PATH" $1 bash -c "
            log_info() { :; }; log_error() { :; }; log_success() { :; }
            ${RESOLVE_DIR_FUNC}
            resolve_config_dir
        " 2>/dev/null
    }

    # 3b-a — .env present, no env vars: the .env value must win over ./configs
    mkdir -p "${_TMPDIR}/envtest"
    printf 'PUID=1000\nDOCKER_CONFIG=%s/from-env-file\n' "${_TMPDIR}" \
        > "${_TMPDIR}/envtest/.env"
    if [[ "$(run_resolve_config_dir "SCRIPT_DIR=${_TMPDIR}/envtest")" == "${_TMPDIR}/from-env-file" ]]; then
        pass "loads DOCKER_CONFIG from .env when no env vars are set"
    else
        fail "did not auto-load DOCKER_CONFIG from .env (issue #29 round 2: script fell back to ./configs despite valid .env)"
    fi

    # 3b-b — shell DOCKER_CONFIG must override .env
    if [[ "$(run_resolve_config_dir "SCRIPT_DIR=${_TMPDIR}/envtest DOCKER_CONFIG=${_TMPDIR}/from-shell")" == "${_TMPDIR}/from-shell" ]]; then
        pass "shell DOCKER_CONFIG overrides .env"
    else
        fail "shell DOCKER_CONFIG must take precedence over .env"
    fi

    # 3b-c — shell CONFIG_DIR outranks both DOCKER_CONFIG and .env
    if [[ "$(run_resolve_config_dir "SCRIPT_DIR=${_TMPDIR}/envtest CONFIG_DIR=${_TMPDIR}/from-config-dir DOCKER_CONFIG=${_TMPDIR}/from-shell")" == "${_TMPDIR}/from-config-dir" ]]; then
        pass "shell CONFIG_DIR outranks DOCKER_CONFIG and .env"
    else
        fail "CONFIG_DIR must be the top-precedence source"
    fi

    # 3b-d — no .env, no env vars: default must remain ./configs
    mkdir -p "${_TMPDIR}/noenv"
    if [[ "$(run_resolve_config_dir "SCRIPT_DIR=${_TMPDIR}/noenv")" == "./configs" ]]; then
        pass "falls back to ./configs when no .env and no env vars"
    else
        fail "default fallback changed; must remain ./configs"
    fi

    # 3b-e — CRLF + quoted value + duplicate key: last line wins, CR/quotes
    #        stripped (users hand-edit .env on Windows)
    mkdir -p "${_TMPDIR}/crlf"
    printf 'DOCKER_CONFIG=/first/stale\r\nDOCKER_CONFIG="%s/second/real"\r\n' "${_TMPDIR}" \
        > "${_TMPDIR}/crlf/.env"
    if [[ "$(run_resolve_config_dir "SCRIPT_DIR=${_TMPDIR}/crlf")" == "${_TMPDIR}/second/real" ]]; then
        pass "last DOCKER_CONFIG line wins, CRLF and quotes stripped"
    else
        fail "must handle CRLF-edited .env, strip quotes, and prefer the last DOCKER_CONFIG= line"
    fi

    # 3b-f — relative DOCKER_CONFIG in .env resolves against SCRIPT_DIR, not
    #        the caller's CWD (matches docker compose's project-dir semantics)
    mkdir -p "${_TMPDIR}/relative"
    printf 'DOCKER_CONFIG=./docker\n' > "${_TMPDIR}/relative/.env"
    if [[ "$(cd /tmp && run_resolve_config_dir "SCRIPT_DIR=${_TMPDIR}/relative")" == "${_TMPDIR}/relative/docker" ]]; then
        pass "relative DOCKER_CONFIG in .env resolves against the script directory"
    else
        fail "relative DOCKER_CONFIG must resolve against SCRIPT_DIR, not the caller's CWD"
    fi

    # 3b-g — get_overseerr_api_key must use resolve_config_dir (shared chain,
    #        no duplicated inline fallback)
    if printf '%s' "${GET_KEY_FUNC}" | grep -q 'resolve_config_dir'; then
        pass "get_overseerr_api_key delegates to resolve_config_dir"
    else
        fail "get_overseerr_api_key must build its path via resolve_config_dir (duplicated fallback chains diverge — that caused #29 round 1)"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 4: Static #29 — set -e guards and indexer list
# ---------------------------------------------------------------------------
section "Phase 4: #29 static — set -e guards + indexer list"

# 4a — the assignment that killed the script must be guarded
if grep -q 'overseerr_api_key=$(get_overseerr_api_key) || overseerr_api_key=""' "${CONFIGURE_SH}"; then
    pass "configure.sh — overseerr_api_key capture is guarded against set -e"
else
    fail "configure.sh — 'overseerr_api_key=\$(get_overseerr_api_key)' must carry '|| overseerr_api_key=\"\"' (issue #29: unguarded capture aborted the script)"
fi

# 4b — every main-level integration step must be guarded so one failure
#      cannot abort the steps after it (this silently skipped the indexers)
for _step in add_qbittorrent_to_radarr add_qbittorrent_to_sonarr \
             add_radarr_root_folder add_sonarr_root_folder \
             add_radarr_to_prowlarr add_sonarr_to_prowlarr \
             add_radarr_to_overseerr add_sonarr_to_overseerr \
             enable_overseerr_watchlist_sync; do
    # The call site (not the definition) must end in a '|| …' guard.
    if grep -E "^\s+${_step} \"" "${CONFIGURE_SH}" | grep -qv '||' ; then
        fail "configure.sh — main-level call to ${_step} is unguarded under set -e"
    else
        pass "configure.sh — ${_step} call site is guarded"
    fi
done

# 4c — log messages inside the \$( ) capture must go to stderr or they vanish
if extract_sh_function "get_overseerr_api_key" | grep -q 'log_error .*>&2'; then
    pass "configure.sh — get_overseerr_api_key logs to stderr (visible during \$() capture)"
else
    fail "configure.sh — get_overseerr_api_key log messages must be redirected to stderr, or failures are silent (issue #29)"
fi

# 4d — TorrentGalaxy definition was deleted upstream; adding it is a
#      guaranteed HTTP 500 for every user
for _file in "${CONFIGURE_SH}" "${CONFIGURE_PS1}"; do
    if grep -qi 'definition.*=.*"torrentgalaxy"\|torrentgalaxy|' "${_file}"; then
        fail "$(basename "${_file}") — still ships the dead TorrentGalaxy indexer"
    else
        pass "$(basename "${_file}") — dead TorrentGalaxy indexer removed"
    fi
done

# 4e — honest indexer summary present in both scripts
if grep -q 'Indexers: ${added} added' "${CONFIGURE_SH}" && \
        grep -q 'Indexers: $added added' "${CONFIGURE_PS1}"; then
    pass "both scripts print an added/skipped/failed indexer summary"
else
    fail "indexer summary line missing from configure.sh or configure.ps1"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n%b%s%b\n" "${BOLD}${CYAN}" "════════════════════════════════════════════════════════════" "${NC}"
printf "  Results: %b%d passed%b, %b%d failed%b, %b%d skipped%b\n" \
    "${GREEN}" "${PASS_COUNT}" "${NC}" \
    "${RED}" "${FAIL_COUNT}" "${NC}" \
    "${YELLOW}" "${SKIP_COUNT}" "${NC}"
printf "%b%s%b\n" "${BOLD}${CYAN}" "════════════════════════════════════════════════════════════" "${NC}"

[[ "${FAIL_COUNT}" -eq 0 ]]
