#!/bin/bash
# =============================================================================
# Simplarr — Pi Compose NFS Path Assertions (TDD Test Suite)
# =============================================================================
# Validates that docker-compose-pi.yml declares all three required NFS
# host-side paths that the Pi/Server split-setup depends on:
#
#   /mnt/nas/downloads   — download landing zone (radarr, sonarr)
#   /mnt/nas/movies      — movies library (radarr, tautulli)
#   /mnt/nas/tv          — TV library (sonarr, tautulli)
#
# These paths are the NFS-mounted directories that the Pi must have
# accessible before services can reach NAS-hosted media.  Absence of any
# path means the volume binding silently maps to a non-existent host
# directory, breaking all media ingestion.
#
# Test Phases:
#   1  File Existence            — docker-compose-pi.yml must be present
#   2  NFS Path Presence         — all three /mnt/nas/* paths must appear
#                                  as host-side volume sources (TDD: FAIL if
#                                  any path absent; PASS once all three exist)
#   3  Per-Service Volume Bindings — each service that requires a path must
#                                    declare the correct host-side mount
#                                    (regression guard for future service edits)
#   4  test.sh Integration       — test.sh must contain the NFS path
#                                  validation logic (TDD: FAIL before the
#                                  phase is added to test.sh, PASS after)
#
# Usage:
#   ./dev-testing/test_pi_nfs_paths.sh
#
# Exit Codes:
#   0 — All tests passed
#   1 — One or more tests failed
#
# No Docker dependency — all assertions are pure grep/awk structural checks
# against the compose file and test.sh on disk.
# =============================================================================

set -uo pipefail

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
printf "  Pi Compose NFS Path Assertions (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

PI_COMPOSE="${PROJECT_ROOT}/docker-compose-pi.yml"
TEST_SH="${PROJECT_ROOT}/dev-testing/test.sh"

# ---------------------------------------------------------------------------
# Phase 1: File Existence
# ---------------------------------------------------------------------------

section "Phase 1: File Existence"

printf "\n"
info "Verifying docker-compose-pi.yml is present before attempting NFS assertions"
printf "\n"

_PI_COMPOSE_PRESENT=true

if [[ -f "${PI_COMPOSE}" ]]; then
    pass "docker-compose-pi.yml — file exists"
else
    fail "docker-compose-pi.yml — file missing (NFS path validation cannot proceed)"
    _PI_COMPOSE_PRESENT=false
fi

# ---------------------------------------------------------------------------
# Phase 2: NFS Host Path Presence
#
# Each of the three paths must appear as a host-side volume source in the
# compose file.  The grep pattern matches the left-hand side of a YAML
# volume binding: '      - /mnt/nas/<dir>:' or '      - /mnt/nas/<dir>/'
# allowing for the colon separator before the container path.
#
# TDD: These assertions FAIL if any path is absent from the compose file.
# They PASS once all three NFS paths are declared in docker-compose-pi.yml.
# ---------------------------------------------------------------------------

section "Phase 2: NFS Host Path Presence"

printf "\n"
info "Asserting all three required NFS host-side paths appear in docker-compose-pi.yml"
printf "\n"

if [[ "${_PI_COMPOSE_PRESENT}" != "true" ]]; then
    skip "/mnt/nas/downloads — docker-compose-pi.yml not found"
    skip "/mnt/nas/movies    — docker-compose-pi.yml not found"
    skip "/mnt/nas/tv        — docker-compose-pi.yml not found"
else
    declare -a NFS_PATHS=(
        "/mnt/nas/downloads"
        "/mnt/nas/movies"
        "/mnt/nas/tv"
    )

    for nfs_path in "${NFS_PATHS[@]}"; do
        # Match the path as a host-side volume source on a volume binding line.
        # The pattern requires the path to be followed by ':' (before the
        # container-side mount point), ruling out lines where it appears only
        # as a comment or a container-side path.
        if grep -qE "^[[:space:]]+-[[:space:]]+${nfs_path}:" "${PI_COMPOSE}"; then
            pass "docker-compose-pi.yml — host path ${nfs_path} is declared as a volume source"
        else
            fail "docker-compose-pi.yml — missing host-side volume source: ${nfs_path}"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 3: Per-Service Volume Binding Completeness
#
# Each service that must access NAS media is asserted to have the correct
# host-side mounts.  This phase guards against future edits that remove a
# path from one service while leaving it in another (which would still pass
# Phase 2 but silently break that service).
#
# Expected bindings:
#   radarr   → /mnt/nas/downloads, /mnt/nas/movies
#   sonarr   → /mnt/nas/downloads, /mnt/nas/tv
#   tautulli → /mnt/nas/movies,    /mnt/nas/tv
# ---------------------------------------------------------------------------

section "Phase 3: Per-Service Volume Binding Completeness"

printf "\n"
info "Asserting each service declares its required NFS volume bindings"
printf "\n"

if [[ "${_PI_COMPOSE_PRESENT}" != "true" ]]; then
    skip "per-service volume binding checks — docker-compose-pi.yml not found"
else
    # Helper: assert that a given service block contains a specific volume binding.
    #
    # Strategy: use awk to extract only the lines within the service's block
    # (from '  <service>:' to the next top-level service or end-of-file), then
    # grep the extracted block for the expected path.  This prevents a path
    # that exists in a different service's block from producing a false positive.
    #
    # Args:
    #   $1  service_name — e.g. "radarr"
    #   $2  nfs_path     — e.g. "/mnt/nas/downloads"
    assert_service_volume() {
        local service="$1"
        local nfs_path="$2"

        local service_block
        service_block=$(awk "
            /^  ${service}:/ { in_block = 1; next }
            in_block && /^  [a-z]/ { exit }
            in_block { print }
        " "${PI_COMPOSE}")

        if printf '%s\n' "${service_block}" | grep -qE "^[[:space:]]+-[[:space:]]+${nfs_path}:"; then
            pass "${service} — volume binding ${nfs_path} is present in service block"
        else
            fail "${service} — missing volume binding: ${nfs_path}"
        fi
    }

    printf "\n"
    info "radarr — downloads + movies (media ingestion and library)"
    assert_service_volume "radarr" "/mnt/nas/downloads"
    assert_service_volume "radarr" "/mnt/nas/movies"

    printf "\n"
    info "sonarr — downloads + tv (media ingestion and library)"
    assert_service_volume "sonarr" "/mnt/nas/downloads"
    assert_service_volume "sonarr" "/mnt/nas/tv"

    printf "\n"
    info "tautulli — movies + tv (play history and statistics)"
    assert_service_volume "tautulli" "/mnt/nas/movies"
    assert_service_volume "tautulli" "/mnt/nas/tv"
fi

# ---------------------------------------------------------------------------
# Phase 4: test.sh Integration
#
# test.sh must contain the NFS path validation logic so that the main test
# suite fails when any expected path is absent from docker-compose-pi.yml.
#
# TDD: These assertions FAIL before the split-setup validation phase is
# added to test.sh (the implementation).  They PASS once test.sh contains
# the grep-based NFS path checks as a phase within the file-validation
# section (Phase 2) or a dedicated split phase.
#
# Checked invariants:
#   4.1  test.sh references docker-compose-pi.yml in the context of NFS
#        path checks (not only in the compose-config phase).
#   4.2  test.sh greps for /mnt/nas/downloads in docker-compose-pi.yml.
#   4.3  test.sh greps for /mnt/nas/movies    in docker-compose-pi.yml.
#   4.4  test.sh greps for /mnt/nas/tv        in docker-compose-pi.yml.
#   4.5  test.sh fails (FAIL_COUNT increment) when a path is absent —
#        i.e., the path checks use fail() not skip(), ensuring the suite
#        exits 1 on missing paths.
# ---------------------------------------------------------------------------

section "Phase 4: test.sh Integration (TDD — fails before implementation)"

printf "\n"
info "Verifying test.sh contains NFS path validation logic for docker-compose-pi.yml"
info "(TDD: these assertions FAIL before the phase is added to test.sh)"
printf "\n"

if [[ ! -f "${TEST_SH}" ]]; then
    skip "Phase 4 — test.sh not found at ${TEST_SH}"
else
    # 4.1 — test.sh must reference docker-compose-pi.yml in an NFS-related context.
    # The implementation should name the compose file when running grep checks so
    # failure messages identify the source file clearly.
    if awk '
        /mnt\/nas/ { found_nfs = 1 }
        found_nfs && /docker-compose-pi\.yml/ { print; exit }
        /docker-compose-pi\.yml/ { nfs_after[NR] = 1 }
    ' "${TEST_SH}" | grep -q .; then
        pass "test.sh — references docker-compose-pi.yml in NFS path validation context"
    else
        # Simpler fallback: both strings appear anywhere in the file AND within
        # close proximity (within 10 lines of each other).  This catches the
        # implementation even if the NFS grep loop iterates a path array.
        _pi_line=$(grep -n 'docker-compose-pi\.yml' "${TEST_SH}" | grep -v 'REQUIRED_FILES\|COMPOSE_FILES\|file not found' | head -1 | cut -d: -f1 || true)
        _nfs_line=$(grep -n '/mnt/nas' "${TEST_SH}" | head -1 | cut -d: -f1 || true)
        if [[ -n "${_pi_line}" && -n "${_nfs_line}" ]]; then
            _delta=$(( _nfs_line - _pi_line ))
            _delta=${_delta#-}   # absolute value
            if [[ "${_delta}" -le 30 ]]; then
                pass "test.sh — NFS path checks appear near docker-compose-pi.yml reference (within 30 lines)"
            else
                fail "test.sh — docker-compose-pi.yml reference and /mnt/nas checks are far apart (${_delta} lines); NFS validation may not be in a split phase"
            fi
        else
            fail "test.sh — missing NFS path validation for docker-compose-pi.yml (no /mnt/nas grep in pi compose context)"
        fi
    fi

    # 4.2 — /mnt/nas/downloads must be checked in test.sh
    if grep -q '/mnt/nas/downloads' "${TEST_SH}"; then
        pass "test.sh — greps for /mnt/nas/downloads"
    else
        fail "test.sh — missing grep for /mnt/nas/downloads (NFS path not validated)"
    fi

    # 4.3 — /mnt/nas/movies must be checked in test.sh
    if grep -q '/mnt/nas/movies' "${TEST_SH}"; then
        pass "test.sh — greps for /mnt/nas/movies"
    else
        fail "test.sh — missing grep for /mnt/nas/movies (NFS path not validated)"
    fi

    # 4.4 — /mnt/nas/tv must be checked in test.sh
    if grep -q '/mnt/nas/tv' "${TEST_SH}"; then
        pass "test.sh — greps for /mnt/nas/tv"
    else
        fail "test.sh — missing grep for /mnt/nas/tv (NFS path not validated)"
    fi

    # 4.5 — The NFS checks must use fail() (not skip()), ensuring the suite
    # exits non-zero when a path is absent.  A skip() would silently pass,
    # defeating the purpose of the validation.
    #
    # Strategy: verify that within the block where /mnt/nas paths are checked,
    # a fail() call is present.  We extract the awk block around the first
    # /mnt/nas reference and look for a fail() call within 10 lines.
    _nfs_fail_check=$(awk '
        /mnt\/nas/ { window = 10 }
        window > 0 {
            if (/fail[[:space:]]*\(/) { print "found"; exit }
            window--
        }
    ' "${TEST_SH}")

    if [[ "${_nfs_fail_check}" == "found" ]]; then
        pass "test.sh — NFS path checks use fail() to signal missing paths (suite will exit 1)"
    else
        fail "test.sh — NFS path checks do not call fail() near /mnt/nas assertions; missing paths may be silently skipped"
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
    printf "\n  TDD note: Phase 4 failures indicate the NFS path validation phase\n"
    printf "  has not yet been added to test.sh.  Phase 2/3 failures indicate\n"
    printf "  docker-compose-pi.yml is missing one or more required NFS paths.\n\n"
    exit 1
fi
