#!/bin/bash
# =============================================================================
# Simplarr — VPN Container Wiring Assertions (TDD Test Suite)
# =============================================================================
# Specifies the required wiring between the gluetun and qbittorrent services
# when VPN mode is enabled. When a user uncomments the VPN blocks in the
# project compose files, the following invariants must hold:
#
#   1. gluetun owns ports 8080 (WebUI) and 6881 (torrent) — not qbittorrent
#   2. qbittorrent carries network_mode: "service:gluetun" (shares gluetun's
#      network namespace so all traffic exits through the VPN tunnel)
#   3. qbittorrent depends_on gluetun with condition: service_healthy so
#      qbittorrent never starts before the VPN tunnel is established
#
# Test Phases:
#   1  File Existence           — required compose files and test.sh present
#   2  Compose VPN Comments     — static grep on commented VPN blocks in
#                                  docker-compose-unified.yml and
#                                  docker-compose-nas.yml
#   3  Compose Config Output    — docker compose config on a minimal VPN
#                                  overlay produces the expected canonical
#                                  YAML (no containers started)
#   4  test.sh Integration      — test.sh must contain Phase 10 VPN wiring
#                                  assertions; FAIL before implementation,
#                                  PASS once Phase 10 is added to test.sh
#
# Usage:
#   ./dev-testing/test_vpn_wiring.sh
#
# Exit Codes:
#   0 — All tests passed
#   1 — One or more tests failed
#
# Notes:
#   Phase 3 is skipped when docker compose is unavailable (CI without Docker).
#   Phase 4 assertions are the TDD "red" state — they FAIL until a developer
#   adds Phase 10 to test.sh, at which point they turn green.
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

# Temp directory for Phase 3 VPN overlay compose file — cleaned up on exit
_VPN_TMPDIR=""

# shellcheck disable=SC2317  # reason: called indirectly via EXIT trap
cleanup() {
    if [[ -n "${_VPN_TMPDIR}" && -d "${_VPN_TMPDIR}" ]]; then
        rm -rf "${_VPN_TMPDIR}"
    fi
}
trap cleanup EXIT

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
printf "  VPN Container Wiring Assertions (TDD)\n"
printf "════════════════════════════════════════════════════════════\n"
printf "%b\n" "${NC}"

UNIFIED_COMPOSE="${PROJECT_ROOT}/docker-compose-unified.yml"
NAS_COMPOSE="${PROJECT_ROOT}/docker-compose-nas.yml"
TEST_SH="${PROJECT_ROOT}/dev-testing/test.sh"

# ---------------------------------------------------------------------------
# Phase 1: File Existence
# ---------------------------------------------------------------------------

section "Phase 1: File Existence"

printf "\n"
info "Verifying required files are present before running VPN wiring assertions"
printf "\n"

_UNIFIED_PRESENT=false
_NAS_PRESENT=false
_TESTSH_PRESENT=false

if [[ -f "${UNIFIED_COMPOSE}" ]]; then
    pass "docker-compose-unified.yml — file exists"
    _UNIFIED_PRESENT=true
else
    fail "docker-compose-unified.yml — file missing"
fi

if [[ -f "${NAS_COMPOSE}" ]]; then
    pass "docker-compose-nas.yml — file exists"
    _NAS_PRESENT=true
else
    fail "docker-compose-nas.yml — file missing"
fi

if [[ -f "${TEST_SH}" ]]; then
    pass "dev-testing/test.sh — file exists"
    _TESTSH_PRESENT=true
else
    fail "dev-testing/test.sh — file missing"
fi

# ---------------------------------------------------------------------------
# Phase 2: VPN Wiring in Compose File Comments
#
# The VPN service blocks are commented out by default in the project compose
# files. These assertions validate that the documented wiring is correct so
# that uncommenting the blocks produces a working configuration.
#
# Checked invariants:
#   2a  gluetun block documents port 8080:8080  (WebUI moves from qbittorrent)
#   2b  gluetun block documents port 6881:6881  (torrent port moves from qbit)
#   2c  qbittorrent VPN override carries network_mode: "service:gluetun"
#   2d  qbittorrent VPN override depends_on gluetun condition: service_healthy
#
# TDD: These PASS immediately if the compose files contain the correct VPN
# wiring in their commented blocks.
# ---------------------------------------------------------------------------

section "Phase 2: VPN Wiring in Compose File Comments"

printf "\n"
info "Static grep assertions on commented VPN blocks — no Docker required"

declare -a _P2_FILES=()
declare -a _P2_LABELS=()

if [[ "${_UNIFIED_PRESENT}" == "true" ]]; then
    _P2_FILES+=("${UNIFIED_COMPOSE}")
    _P2_LABELS+=("docker-compose-unified.yml")
else
    skip "Phase 2 — docker-compose-unified.yml — file not found"
fi

if [[ "${_NAS_PRESENT}" == "true" ]]; then
    _P2_FILES+=("${NAS_COMPOSE}")
    _P2_LABELS+=("docker-compose-nas.yml")
else
    skip "Phase 2 — docker-compose-nas.yml — file not found"
fi

for _i in "${!_P2_FILES[@]}"; do
    _p2_file="${_P2_FILES[${_i}]}"
    _p2_label="${_P2_LABELS[${_i}]}"

    printf "\n"
    info "${_p2_label} — gluetun + qbittorrent VPN override wiring"

    # 2a — gluetun must own port 8080; qbittorrent WebUI moves here when VPN enabled.
    # Pattern matches commented YAML port binding lines: '#      - 8080:8080'
    if grep -qE '^#[[:space:]]+-[[:space:]]+8080:8080' "${_p2_file}"; then
        pass "${_p2_label}: gluetun block documents port 8080:8080"
    else
        fail "${_p2_label}: gluetun block missing port 8080:8080"
    fi

    # 2b — gluetun must own port 6881; torrent port moves here when VPN enabled.
    if grep -qE '^#[[:space:]]+-[[:space:]]+6881:6881' "${_p2_file}"; then
        pass "${_p2_label}: gluetun block documents port 6881:6881"
    else
        fail "${_p2_label}: gluetun block missing port 6881:6881"
    fi

    # 2c — qbittorrent VPN override routes all traffic through gluetun's network stack.
    # Absence means qbittorrent would have its own IP and bypass the VPN tunnel.
    if grep -qE '^#[[:space:]]+network_mode:[[:space:]]+"service:gluetun"' "${_p2_file}"; then
        pass "${_p2_label}: qbittorrent VPN override carries network_mode: \"service:gluetun\""
    else
        fail "${_p2_label}: qbittorrent VPN override missing network_mode: \"service:gluetun\""
    fi

    # 2d — qbittorrent must not start until gluetun is healthy.
    # Without this, qbittorrent could start before the tunnel is up, leaking traffic.
    if grep -qE '^#[[:space:]]+condition:[[:space:]]+service_healthy' "${_p2_file}"; then
        pass "${_p2_label}: qbittorrent VPN override depends_on gluetun condition: service_healthy"
    else
        fail "${_p2_label}: qbittorrent VPN override missing depends_on gluetun condition: service_healthy"
    fi
done

# ---------------------------------------------------------------------------
# Phase 3: docker compose config — VPN Overlay Canonical YAML
#
# Generates a minimal VPN-enabled compose file mirroring the commented blocks
# in the project compose files and runs 'docker compose config' to obtain the
# canonical resolved YAML. Parses the output to assert correct wiring.
#
# No containers are started — this is a pure YAML validation.
#
# Checked invariants:
#   3a  VPN overlay YAML is valid (docker compose config exits 0)
#   3b  qbittorrent carries network_mode: service:gluetun in resolved output
#   3c  port 8080 appears under gluetun (published: "8080" in canonical form)
#   3d  port 6881 appears under gluetun (published: "6881" in canonical form)
#   3e  qbittorrent depends_on gluetun with condition: service_healthy
#
# Skipped when docker compose is not available (e.g. CI without Docker).
# ---------------------------------------------------------------------------

section "Phase 3: docker compose config — VPN Overlay Canonical YAML"

printf "\n"
info "Phase 3: Running docker compose config on a VPN-wiring overlay — no containers"

# Detect docker compose — mirrors Phase 1 logic from test.sh
_P3_DC_AVAILABLE=false
declare -a _P3_DC_CMD=()

if command -v docker &>/dev/null; then
    if docker compose version &>/dev/null 2>&1; then
        _P3_DC_CMD=("docker" "compose")
        _P3_DC_AVAILABLE=true
    elif command -v docker-compose &>/dev/null; then
        _P3_DC_CMD=("docker-compose")
        _P3_DC_AVAILABLE=true
    fi
fi

if [[ "${_P3_DC_AVAILABLE}" != "true" ]]; then
    skip "Phase 3a — VPN overlay YAML validation — docker compose not available"
    skip "Phase 3b — qbittorrent network_mode: service:gluetun — docker compose not available"
    skip "Phase 3c — port 8080 in gluetun config — docker compose not available"
    skip "Phase 3d — port 6881 in gluetun config — docker compose not available"
    skip "Phase 3e — depends_on gluetun condition: service_healthy — docker compose not available"
else
    _VPN_TMPDIR="$(mktemp -d -t "simplarr-vpn-tdd-XXXXXX")"

    # Write a minimal VPN-enabled compose file. Mirrors the gluetun and
    # qbittorrent VPN override blocks that are commented out in the project
    # compose files. Hard-coded values avoid env var interpolation issues.
    cat > "${_VPN_TMPDIR}/vpn-wiring-test.yml" << 'VPN_COMPOSE_EOF'
services:
  gluetun:
    image: qmcgaw/gluetun:v3.41.1
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    environment:
      - VPN_SERVICE_PROVIDER=mullvad
      - VPN_TYPE=openvpn
      - OPENVPN_USER=test-user
      - OPENVPN_PASSWORD=test-password
      - WIREGUARD_PRIVATE_KEY=test-key
      - WIREGUARD_ADDRESSES=10.64.0.1/32
      - SERVER_COUNTRIES=Netherlands
      - TZ=UTC
    volumes:
      - /tmp/simplarr-vpn-test/gluetun:/gluetun
    healthcheck:
      test: ["CMD", "/gluetun-entrypoint", "healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    restart: unless-stopped

  qbittorrent:
    image: linuxserver/qbittorrent:5.1.4-r2-ls443
    network_mode: "service:gluetun"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
      - WEBUI_PORT=8080
    volumes:
      - /tmp/simplarr-vpn-test/qbittorrent:/config
    healthcheck:
      test: curl -f http://localhost:8080 || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    depends_on:
      gluetun:
        condition: service_healthy
    restart: unless-stopped
VPN_COMPOSE_EOF

    # 3a — docker compose config must accept the VPN overlay as valid YAML
    _P3_CONF_OUT=""
    if _P3_CONF_OUT=$("${_P3_DC_CMD[@]}" \
            -f "${_VPN_TMPDIR}/vpn-wiring-test.yml" \
            config 2>&1); then
        pass "Phase 3a — VPN overlay YAML is valid (docker compose config exits 0)"
    else
        fail "Phase 3a — VPN overlay YAML is invalid: ${_P3_CONF_OUT}"
        _P3_CONF_OUT=""
    fi

    if [[ -n "${_P3_CONF_OUT}" ]]; then
        # 3b — qbittorrent must carry network_mode: service:gluetun (compose drops quotes)
        if echo "${_P3_CONF_OUT}" | grep -qE 'network_mode:[[:space:]]+service:gluetun'; then
            pass "Phase 3b — qbittorrent carries network_mode: service:gluetun in resolved YAML"
        else
            fail "Phase 3b — qbittorrent missing network_mode: service:gluetun in resolved YAML"
        fi

        # 3c — port 8080 must appear in gluetun's service block.
        # docker compose v2 canonical form: published: "8080"
        # docker compose v1 form: - "8080:8080"
        if echo "${_P3_CONF_OUT}" | grep -qE 'published:[[:space:]]+"?8080"?|"8080:8080"|8080:8080'; then
            pass "Phase 3c — port 8080 appears in gluetun service (WebUI port owned by gluetun)"
        else
            fail "Phase 3c — port 8080 missing from resolved config (expected under gluetun)"
        fi

        # 3d — port 6881 must appear in gluetun's service block (torrent port)
        if echo "${_P3_CONF_OUT}" | grep -qE 'published:[[:space:]]+"?6881"?|"6881:6881"|6881:6881'; then
            pass "Phase 3d — port 6881 appears in gluetun service (torrent port owned by gluetun)"
        else
            fail "Phase 3d — port 6881 missing from resolved config (expected under gluetun)"
        fi

        # 3e — qbittorrent must depend on gluetun with condition: service_healthy
        if echo "${_P3_CONF_OUT}" | grep -qE 'condition:[[:space:]]+service_healthy'; then
            pass "Phase 3e — qbittorrent depends_on gluetun with condition: service_healthy"
        else
            fail "Phase 3e — missing depends_on gluetun condition: service_healthy in resolved YAML"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Phase 4: test.sh Integration
#
# test.sh must contain a Phase 10 section that asserts VPN container wiring.
# These checks verify the implementation exists; they define the minimum
# required content of the Phase 10 block.
#
# TDD: These assertions FAIL before Phase 10 is added to test.sh.
#      They PASS once the developer implements Phase 10 in test.sh.
#
# Checked invariants:
#   4.1  test.sh has a "Phase 10" header or VPN Container Wiring section
#   4.2  test.sh asserts qbittorrent carries network_mode: service:gluetun
#   4.3  test.sh asserts gluetun owns port 8080
#   4.4  test.sh asserts gluetun owns port 6881
#   4.5  test.sh checks /dev/net/tun presence for the runtime guard
#   4.6  test.sh emits SKIP with "TUN device not available" when absent
#   4.7  test.sh always skips VPN connectivity with "real VPN credentials required"
# ---------------------------------------------------------------------------

section "Phase 4: test.sh Integration (TDD — fails before Phase 10 is added)"

printf "\n"
info "Verifying test.sh contains Phase 10 VPN container wiring assertions"
info "(TDD: these assertions FAIL before Phase 10 is added to test.sh)"
printf "\n"

if [[ "${_TESTSH_PRESENT}" != "true" ]]; then
    skip "Phase 4 — test.sh not found at ${TEST_SH}"
else
    # 4.1 — test.sh must have a Phase 10 or VPN Container Wiring section header
    if grep -qE 'Phase 10|VPN Container Wiring' "${TEST_SH}"; then
        pass "test.sh — Phase 10 VPN Container Wiring section is present"
    else
        fail "test.sh — missing Phase 10 VPN Container Wiring section (add Phase 10 to test.sh)"
    fi

    # 4.2 — test.sh must assert qbittorrent carries network_mode: service:gluetun
    if grep -qE 'network_mode.*service:gluetun|service:gluetun' "${TEST_SH}"; then
        pass "test.sh — asserts qbittorrent carries network_mode: service:gluetun"
    else
        fail "test.sh — missing assertion for qbittorrent network_mode: service:gluetun"
    fi

    # 4.3 — test.sh must assert port 8080 belongs to gluetun (not qbittorrent)
    if grep -qE '8080.*gluetun|gluetun.*8080' "${TEST_SH}"; then
        pass "test.sh — asserts gluetun owns port 8080"
    else
        fail "test.sh — missing assertion linking port 8080 to gluetun service"
    fi

    # 4.4 — test.sh must assert port 6881 belongs to gluetun (not qbittorrent)
    if grep -qE '6881.*gluetun|gluetun.*6881' "${TEST_SH}"; then
        pass "test.sh — asserts gluetun owns port 6881"
    else
        fail "test.sh — missing assertion linking port 6881 to gluetun service"
    fi

    # 4.5 — test.sh must check /dev/net/tun to guard runtime assertions
    if grep -q '/dev/net/tun' "${TEST_SH}"; then
        pass "test.sh — /dev/net/tun presence check is included (runtime guard)"
    else
        fail "test.sh — missing /dev/net/tun presence check (runtime tests must be guarded)"
    fi

    # 4.6 — test.sh must emit SKIP with "TUN device not available" when /dev/net/tun absent
    if grep -q 'TUN device not available' "${TEST_SH}"; then
        pass "test.sh — emits SKIP 'TUN device not available' when /dev/net/tun absent"
    else
        fail "test.sh — missing SKIP message 'TUN device not available'"
    fi

    # 4.7 — test.sh must always skip VPN connectivity with the exact required message
    if grep -q 'real VPN credentials required' "${TEST_SH}"; then
        pass "test.sh — always skips VPN connectivity with 'real VPN credentials required'"
    else
        fail "test.sh — missing SKIP message 'real VPN credentials required'"
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
    printf "\n  TDD note: Phase 4 failures indicate Phase 10 VPN wiring assertions\n"
    printf "  have not yet been added to test.sh. Add Phase 10 to test.sh to\n"
    printf "  satisfy these checks. Phase 2/3 failures indicate the compose files\n"
    printf "  or VPN overlay have incorrect wiring.\n\n"
    exit 1
fi
