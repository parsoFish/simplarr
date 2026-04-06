#!/bin/bash
# =============================================================================
# NAS Mount Monitor — Behavioral Unit Tests
# =============================================================================
# PURPOSE:
#   Exercises check_nas_mounts.sh using PATH-injected mock binaries.
#   All three core behavioral scenarios are covered:
#     1. NAS reachable and all fstab mounts mounted — no action, exit 0
#     2. NAS reachable but a mount missing           — mount -a attempted
#     3. NAS unreachable                             — email alert + exit 1
#
# APPROACH:
#   Each scenario creates an isolated temp directory containing mock binaries
#   (ping, mountpoint, mount, msmtp, sleep, docker-compose, grep).  The temp
#   bin/ is prepended to PATH when running the script.  HOME is redirected to
#   a temp dir so LOG_FILE lands there instead of the real $HOME.  Assertions
#   inspect exit codes, log file content, and call-tracking state files written
#   by the mock binaries.
#
# NOTES:
#   - Tests run without real network, NAS hardware, or root privileges.
#   - This is a TDD test file.  Tests MUST fail if check_nas_mounts.sh does
#     not implement the three scenarios described above.
#
# Usage:
#   ./dev-testing/test_nas_mounts.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths and colours
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_UNDER_TEST="${PROJECT_ROOT}/utility/check_nas_mounts.sh"

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

skip() {
    printf '  %s[SKIP]%s %s\n' "${YELLOW}" "${NC}" "$1"
    (( SKIP_COUNT++ )) || true
}

info() {
    printf '  %s[INFO]%s %s\n' "${BLUE}" "${NC}" "$1"
}

section() {
    printf '\n%s%s%s%s\n' "${BOLD}" "${CYAN}" "$1" "${NC}"
    printf '%s%s%s\n' "${CYAN}" "────────────────────────────────────────────────────────────" "${NC}"
}

# ---------------------------------------------------------------------------
# Cleanup — track temp dirs via a file so subshells can append to it
# ---------------------------------------------------------------------------

_TMPDIR_TRACK="$(mktemp -t "nas-test-track-XXXXXX")"

cleanup() {
    while IFS= read -r d; do
        [[ -n "${d}" && -d "${d}" ]] && rm -rf "${d}"
    done < "${_TMPDIR_TRACK}" 2>/dev/null || true
    rm -f "${_TMPDIR_TRACK}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf '\n%s%s' "${BOLD}" "${CYAN}"
printf '════════════════════════════════════════════════════════════\n'
printf '  NAS Mount Monitor — Behavioral Unit Tests\n'
printf '════════════════════════════════════════════════════════════\n'
printf '%s\n' "${NC}"

# =============================================================================
# Pre-flight — verify the script under test exists and has no syntax errors
# =============================================================================

section "Pre-flight"

if [[ -f "${SCRIPT_UNDER_TEST}" ]]; then
    pass "utility/check_nas_mounts.sh exists"
else
    fail "utility/check_nas_mounts.sh not found (expected at ${SCRIPT_UNDER_TEST})"
    printf '\n%sCannot continue: script under test is missing.%s\n\n' "${RED}" "${NC}"
    exit 1
fi

if bash -n "${SCRIPT_UNDER_TEST}" 2>/dev/null; then
    pass "utility/check_nas_mounts.sh passes bash -n syntax check"
else
    SYNTAX_ERR="$(bash -n "${SCRIPT_UNDER_TEST}" 2>&1 || true)"
    fail "utility/check_nas_mounts.sh has bash syntax errors: ${SYNTAX_ERR}"
fi

# =============================================================================
# create_mock_env — build an isolated temp directory with mock binaries
# =============================================================================
#
# Writes mock binaries for every external command the script invokes.
# All mocks record their invocations via call-tracking files under state/.
#
# Arguments:
#   $1  nas_reachable     — "true"|"false"  controls mock ping exit code
#   $2  mount_present     — "true"|"false"  controls initial mountpoint result
#   $3  remount_succeeds  — "true"|"false"  controls post-remount mountpoint result
#
# Prints the tmpdir path to stdout (caller captures via $(...)).
# Also appends the path to _TMPDIR_TRACK so the EXIT trap can remove it.
# ---------------------------------------------------------------------------

create_mock_env() {
    local nas_reachable="$1"
    local mount_present="$2"
    local remount_succeeds="$3"

    local tmpdir
    tmpdir="$(mktemp -d -t "nas-test-XXXXXX")"

    # Register for cleanup (file write works even from a subshell)
    printf '%s\n' "${tmpdir}" >> "${_TMPDIR_TRACK}"

    mkdir -p "${tmpdir}/bin"
    mkdir -p "${tmpdir}/state"
    mkdir -p "${tmpdir}/home/simplarr"   # mirrors $HOME/simplarr (DOCKER_COMPOSE_DIR)

    # -----------------------------------------------------------------------
    # Fake fstab content
    # -----------------------------------------------------------------------
    # The script greps /etc/fstab for lines matching ^NAS_IP or ^//.*NAS_IP.
    # NAS_IP is hardcoded in the script as "YOUR_NAS_IP".  This NFS line
    # matches the ^YOUR_NAS_IP branch of the grep pattern.
    # -----------------------------------------------------------------------
    printf 'YOUR_NAS_IP:/volume1/media /mnt/nas/media nfs defaults 0 0\n' \
        > "${tmpdir}/fstab"

    # -----------------------------------------------------------------------
    # Mock: ping
    # -----------------------------------------------------------------------
    # Returns 0 (reachable) or 1 (unreachable) according to nas_reachable.
    # Records its invocation in state/calls.log and state/ping_called.
    # -----------------------------------------------------------------------
    cat > "${tmpdir}/bin/ping" <<MOCK_PING
#!/bin/bash
printf 'ping %s\n' "\$*" >> "${tmpdir}/state/calls.log"
touch "${tmpdir}/state/ping_called"
if [[ "${nas_reachable}" == "true" ]]; then
    exit 0
else
    exit 1
fi
MOCK_PING

    # -----------------------------------------------------------------------
    # Mock: mountpoint
    # -----------------------------------------------------------------------
    # Uses a per-scenario call counter (written to a file) to return
    # different values across calls within a single script run:
    #
    #   mount_present == "true"  → always exits 0 (mount is present)
    #   mount_present == "false", remount_succeeds == "true":
    #       call 1 → exits 1 (initial check: not mounted)
    #       call 2+ → exits 0 (post-remount check: now mounted)
    #   mount_present == "false", remount_succeeds == "false":
    #       always exits 1 (never mounts successfully)
    # -----------------------------------------------------------------------
    cat > "${tmpdir}/bin/mountpoint" <<MOCK_MOUNTPOINT
#!/bin/bash
printf 'mountpoint %s\n' "\$*" >> "${tmpdir}/state/calls.log"
touch "${tmpdir}/state/mountpoint_called"

CALL_FILE="${tmpdir}/state/mountpoint_call_count"
count=0
if [[ -f "\${CALL_FILE}" ]]; then
    count=\$(cat "\${CALL_FILE}")
fi
count=\$(( count + 1 ))
printf '%d\n' "\${count}" > "\${CALL_FILE}"

if [[ "${mount_present}" == "true" ]]; then
    exit 0
elif [[ "${remount_succeeds}" == "true" && "\${count}" -ge 2 ]]; then
    exit 0
else
    exit 1
fi
MOCK_MOUNTPOINT

    # -----------------------------------------------------------------------
    # Mock: mount
    # -----------------------------------------------------------------------
    # Records invocation; exits 0 to simulate a successful remount trigger.
    # -----------------------------------------------------------------------
    cat > "${tmpdir}/bin/mount" <<MOCK_MOUNT
#!/bin/bash
printf 'mount %s\n' "\$*" >> "${tmpdir}/state/calls.log"
touch "${tmpdir}/state/mount_called"
exit 0
MOCK_MOUNT

    # -----------------------------------------------------------------------
    # Mock: msmtp
    # -----------------------------------------------------------------------
    # Records invocation, captures CLI arguments and stdin so assertions
    # can verify the recipient address and email subject.
    # -----------------------------------------------------------------------
    cat > "${tmpdir}/bin/msmtp" <<MOCK_MSMTP
#!/bin/bash
printf 'msmtp %s\n' "\$*" >> "${tmpdir}/state/calls.log"
touch "${tmpdir}/state/msmtp_called"
printf '%s\n' "\$*" >> "${tmpdir}/state/msmtp_args"
cat >> "${tmpdir}/state/msmtp_stdin"
exit 0
MOCK_MSMTP

    # -----------------------------------------------------------------------
    # Mock: sleep
    # -----------------------------------------------------------------------
    # No-op — eliminates the 2 s and 3 s delays embedded in the script so
    # the test suite runs in milliseconds.
    # -----------------------------------------------------------------------
    cat > "${tmpdir}/bin/sleep" <<MOCK_SLEEP
#!/bin/bash
printf 'sleep %s\n' "\$*" >> "${tmpdir}/state/calls.log"
exit 0
MOCK_SLEEP

    # -----------------------------------------------------------------------
    # Mock: docker-compose
    # -----------------------------------------------------------------------
    # Records invocation; exits 0.  The script calls docker-compose after a
    # successful remount to restart containers.
    # -----------------------------------------------------------------------
    cat > "${tmpdir}/bin/docker-compose" <<MOCK_DC
#!/bin/bash
printf 'docker-compose %s\n' "\$*" >> "${tmpdir}/state/calls.log"
touch "${tmpdir}/state/docker_compose_called"
exit 0
MOCK_DC

    # -----------------------------------------------------------------------
    # Mock: grep
    # -----------------------------------------------------------------------
    # Intercepts calls that include /etc/fstab as an argument and returns the
    # scenario-specific fake fstab content.  All other grep calls (none
    # expected, but guarded for safety) are delegated to the system grep.
    # -----------------------------------------------------------------------
    local real_grep
    real_grep="$(command -v grep 2>/dev/null)" || real_grep="/usr/bin/grep"
    cat > "${tmpdir}/bin/grep" <<MOCK_GREP
#!/bin/bash
for arg in "\$@"; do
    if [[ "\${arg}" == "/etc/fstab" ]]; then
        printf 'grep (fstab intercept)\n' >> "${tmpdir}/state/calls.log"
        cat "${tmpdir}/fstab"
        exit 0
    fi
done
exec "${real_grep}" "\$@"
MOCK_GREP

    chmod +x "${tmpdir}/bin/"*

    printf '%s\n' "${tmpdir}"
}

# ---------------------------------------------------------------------------
# assert_log_contains / assert_log_not_contains
#
# Check the script's log file for a fixed-string pattern.
# On failure, print the full log to help diagnose problems.
# ---------------------------------------------------------------------------

assert_log_contains() {
    local log_file="$1"
    local pattern="$2"
    local description="$3"

    if grep -qF "${pattern}" "${log_file}" 2>/dev/null; then
        pass "${description}"
    else
        fail "${description}"
        if [[ -f "${log_file}" ]]; then
            info "  Expected '${pattern}' — log contents:"
            while IFS= read -r line; do
                info "    ${line}"
            done < "${log_file}"
        else
            info "  Log file does not exist: ${log_file}"
        fi
    fi
}

assert_log_not_contains() {
    local log_file="$1"
    local pattern="$2"
    local description="$3"

    if grep -qF "${pattern}" "${log_file}" 2>/dev/null; then
        fail "${description}"
        info "  Unexpected pattern found: '${pattern}'"
    else
        pass "${description}"
    fi
}

# =============================================================================
# Scenario 1: NAS reachable and all mounts present — no action, exit 0
# =============================================================================

section "Scenario 1: NAS reachable, all mounts present — expect exit 0, no action"

info "Creating mock environment (ping=ok, mountpoint=ok)..."
S1_DIR="$(create_mock_env "true" "true" "true")"
S1_LOG="${S1_DIR}/home/nas_monitor.log"

info "Running check_nas_mounts.sh..."
S1_EXIT=0
HOME="${S1_DIR}/home" \
PATH="${S1_DIR}/bin:${PATH}" \
    bash "${SCRIPT_UNDER_TEST}" \
    >"${S1_DIR}/stdout" 2>"${S1_DIR}/stderr" \
    || S1_EXIT=$?

# --- Exit code ---------------------------------------------------------------
if [[ "${S1_EXIT}" -eq 0 ]]; then
    pass "Scenario 1 — exits 0 when NAS is reachable and all mounts present"
else
    fail "Scenario 1 — expected exit 0; got ${S1_EXIT}"
fi

# --- Log file was created ----------------------------------------------------
if [[ -f "${S1_LOG}" ]]; then
    pass "Scenario 1 — log file created at \$HOME/nas_monitor.log"
else
    fail "Scenario 1 — log file not created (expected at ${S1_LOG})"
fi

# --- Log content: start banner -----------------------------------------------
assert_log_contains "${S1_LOG}" "Starting NAS check" \
    "Scenario 1 — log records 'Starting NAS check'"

# --- Log content: NAS reachable ----------------------------------------------
assert_log_contains "${S1_LOG}" "NAS is reachable on the network" \
    "Scenario 1 — log records NAS as reachable"

# --- Log content: mount healthy ----------------------------------------------
assert_log_contains "${S1_LOG}" "Mount OK:" \
    "Scenario 1 — log records the mount as OK"

# --- Log content: healthy summary --------------------------------------------
assert_log_contains "${S1_LOG}" "All NAS mounts are healthy" \
    "Scenario 1 — log records 'All NAS mounts are healthy'"

# --- mount -a was NOT called -------------------------------------------------
if [[ ! -f "${S1_DIR}/state/mount_called" ]]; then
    pass "Scenario 1 — mount -a was NOT called (no remount needed)"
else
    fail "Scenario 1 — mount -a was unexpectedly called"
fi

# --- msmtp was NOT called ----------------------------------------------------
if [[ ! -f "${S1_DIR}/state/msmtp_called" ]]; then
    pass "Scenario 1 — msmtp was NOT called (no alert needed)"
else
    fail "Scenario 1 — msmtp was unexpectedly called; no alert should fire when healthy"
fi

# =============================================================================
# Scenario 2: NAS reachable, mount missing — mount -a attempted, succeeds
# =============================================================================

section "Scenario 2: NAS reachable, mount missing — remount succeeds, expect exit 0"

info "Creating mock environment (ping=ok, mountpoint=initially-missing, remount=ok)..."
S2_DIR="$(create_mock_env "true" "false" "true")"
S2_LOG="${S2_DIR}/home/nas_monitor.log"

info "Running check_nas_mounts.sh..."
S2_EXIT=0
HOME="${S2_DIR}/home" \
PATH="${S2_DIR}/bin:${PATH}" \
    bash "${SCRIPT_UNDER_TEST}" \
    >"${S2_DIR}/stdout" 2>"${S2_DIR}/stderr" \
    || S2_EXIT=$?

# --- Exit code ---------------------------------------------------------------
if [[ "${S2_EXIT}" -eq 0 ]]; then
    pass "Scenario 2 — exits 0 after successful remount"
else
    fail "Scenario 2 — expected exit 0 after remount; got ${S2_EXIT}"
fi

# --- Log content: initial mount failure detected -----------------------------
assert_log_contains "${S2_LOG}" "Mount FAILED:" \
    "Scenario 2 — log records the initial mount failure"

# --- Log content: remount attempt logged -------------------------------------
assert_log_contains "${S2_LOG}" "Attempting to remount" \
    "Scenario 2 — log records remount attempt"

# --- mount -a WAS called -----------------------------------------------------
if [[ -f "${S2_DIR}/state/mount_called" ]]; then
    pass "Scenario 2 — mount -a was called to restore the failed mount"
else
    fail "Scenario 2 — mount -a was NOT called (expected remount attempt)"
fi

# --- Verify mount -a called with -a flag ------------------------------------
if [[ -f "${S2_DIR}/state/calls.log" ]] && grep -q "^mount -a" "${S2_DIR}/state/calls.log" 2>/dev/null; then
    pass "Scenario 2 — mount was called with the -a flag (mount all fstab entries)"
else
    fail "Scenario 2 — mount -a not found in call log (expected 'mount -a')"
fi

# --- Log content: remount success --------------------------------------------
assert_log_contains "${S2_LOG}" "Remount SUCCESS:" \
    "Scenario 2 — log records remount success for the mount point"

# --- Log content: all restored -----------------------------------------------
assert_log_contains "${S2_LOG}" "All mounts successfully restored" \
    "Scenario 2 — log records 'All mounts successfully restored'"

# --- msmtp was NOT called (remount succeeded) --------------------------------
if [[ ! -f "${S2_DIR}/state/msmtp_called" ]]; then
    pass "Scenario 2 — msmtp was NOT called (no alert; remount succeeded)"
else
    fail "Scenario 2 — msmtp was unexpectedly called; no alert should fire on successful remount"
fi

# --- docker-compose was called to restart containers -------------------------
if [[ -f "${S2_DIR}/state/docker_compose_called" ]]; then
    pass "Scenario 2 — docker-compose was called to restart containers after remount"
else
    fail "Scenario 2 — docker-compose was NOT called (should restart containers after successful remount)"
fi

# =============================================================================
# Scenario 3: NAS unreachable — alert email triggered, exit 1
# =============================================================================

section "Scenario 3: NAS unreachable — email alert triggered, expect exit 1"

info "Creating mock environment (ping=fail)..."
S3_DIR="$(create_mock_env "false" "false" "false")"
S3_LOG="${S3_DIR}/home/nas_monitor.log"

info "Running check_nas_mounts.sh..."
S3_EXIT=0
HOME="${S3_DIR}/home" \
PATH="${S3_DIR}/bin:${PATH}" \
    bash "${SCRIPT_UNDER_TEST}" \
    >"${S3_DIR}/stdout" 2>"${S3_DIR}/stderr" \
    || S3_EXIT=$?

# --- Exit code ---------------------------------------------------------------
if [[ "${S3_EXIT}" -eq 1 ]]; then
    pass "Scenario 3 — exits 1 when NAS is unreachable"
else
    fail "Scenario 3 — expected exit 1; got ${S3_EXIT}"
fi

# --- Log content: start banner -----------------------------------------------
assert_log_contains "${S3_LOG}" "Starting NAS check" \
    "Scenario 3 — log records 'Starting NAS check'"

# --- Log content: error message ----------------------------------------------
assert_log_contains "${S3_LOG}" "ERROR:" \
    "Scenario 3 — log records an ERROR entry"

# --- Log content: NAS IP referenced ------------------------------------------
assert_log_contains "${S3_LOG}" "YOUR_NAS_IP" \
    "Scenario 3 — log references the NAS IP in the error message"

# --- msmtp WAS called --------------------------------------------------------
if [[ -f "${S3_DIR}/state/msmtp_called" ]]; then
    pass "Scenario 3 — msmtp was called to send the alert email"
else
    fail "Scenario 3 — msmtp was NOT called (alert email should be sent when NAS is unreachable)"
fi

# --- msmtp received the correct recipient ------------------------------------
if [[ -f "${S3_DIR}/state/msmtp_args" ]]; then
    if grep -q "your.email@example.com" "${S3_DIR}/state/msmtp_args" 2>/dev/null; then
        pass "Scenario 3 — msmtp was called with the configured email recipient"
    else
        fail "Scenario 3 — msmtp was not called with 'your.email@example.com'"
        info "  msmtp args: $(cat "${S3_DIR}/state/msmtp_args" 2>/dev/null || echo "(empty)")"
    fi
else
    fail "Scenario 3 — msmtp_args state file not found (msmtp may not have been called)"
fi

# --- Email subject contains 'NAS Alert' --------------------------------------
if [[ -f "${S3_DIR}/state/msmtp_stdin" ]]; then
    if grep -q "NAS Alert" "${S3_DIR}/state/msmtp_stdin" 2>/dev/null; then
        pass "Scenario 3 — alert email subject contains 'NAS Alert'"
    else
        fail "Scenario 3 — alert email subject does not contain 'NAS Alert'"
        info "  msmtp stdin (first 3 lines):"
        head -3 "${S3_DIR}/state/msmtp_stdin" 2>/dev/null | while IFS= read -r line; do
            info "    ${line}"
        done
    fi
else
    fail "Scenario 3 — msmtp_stdin state file not found (email body not captured)"
fi

# --- mountpoint was NOT called (script exits before mount check) -------------
if [[ ! -f "${S3_DIR}/state/mountpoint_called" ]]; then
    pass "Scenario 3 — mountpoint was NOT called (script exits at NAS unreachable)"
else
    fail "Scenario 3 — mountpoint was unexpectedly called after NAS unreachable detection"
fi

# --- mount was NOT called (script exits before remount attempt) --------------
if [[ ! -f "${S3_DIR}/state/mount_called" ]]; then
    pass "Scenario 3 — mount -a was NOT called (script exits at NAS unreachable)"
else
    fail "Scenario 3 — mount -a was unexpectedly called after NAS unreachable detection"
fi

# =============================================================================
# Summary
# =============================================================================

printf '\n%s%s' "${BOLD}" "${CYAN}"
printf '════════════════════════════════════════════════════════════\n'
printf '  Summary\n'
printf '════════════════════════════════════════════════════════════\n'
printf '%s\n' "${NC}"

printf '  %sPassed:%s  %d\n' "${GREEN}" "${NC}" "${PASS_COUNT}"
printf '  %sFailed:%s  %d\n' "${RED}" "${NC}" "${FAIL_COUNT}"
printf '  %sSkipped:%s %d\n' "${YELLOW}" "${NC}" "${SKIP_COUNT}"
printf '\n'

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    printf '  %s%sAll tests passed.%s\n\n' "${GREEN}" "${BOLD}" "${NC}"
    exit 0
else
    printf '  %s%s%d test(s) failed.%s\n\n' "${RED}" "${BOLD}" "${FAIL_COUNT}" "${NC}"
    exit 1
fi
