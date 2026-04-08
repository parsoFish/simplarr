#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # reason: each bats @test runs in its own subshell;
#   variable-scope warnings (SC2030/SC2031) are false positives for this pattern.
# =============================================================================
# configure.sh — port parameterisation & retry configuration unit tests
# =============================================================================
# Tests verify that:
#   • RADARR_PORT and SONARR_PORT env vars are declared in configure.sh with
#     the correct defaults (7878 / 8989).
#   • WAIT_MAX_ATTEMPTS and WAIT_RETRY_SECS env vars are declared in
#     configure.sh with the correct defaults (30 / 2).
#   • add_radarr_to_overseerr() sends the value of RADARR_PORT — not a
#     hard-coded literal — in the JSON payload POSTed to Overseerr.
#   • add_sonarr_to_overseerr() sends the value of SONARR_PORT in the same way.
#     Acceptance criterion: SONARR_PORT=29989 → Overseerr receives "port": 29989.
#   • wait_for_service() references WAIT_MAX_ATTEMPTS and WAIT_RETRY_SECS
#     rather than the hard-coded literals 30 and 2.
#
# All tests are written TDD-style: they MUST FAIL on the current (unmodified)
# configure.sh because the env vars are not yet declared and the port literals
# are still hard-coded.
#
# Requirements:
#   bats-core >= 1.5.0
#   Install: https://github.com/bats-core/bats-core#installation
#            sudo apt install bats  (Ubuntu / Debian)
#            brew install bats-core (macOS)
# =============================================================================

CONFIGURE_SH="${BATS_TEST_DIRNAME}/../configure.sh"

# =============================================================================
# File-level setup: create a function-only testable copy of configure.sh by
# stripping the unconditional "main "$@"" invocation at the bottom.  This
# lets individual tests source the file to load function definitions without
# triggering live service calls.
# =============================================================================

setup_file() {
    export CONFIGURE_FUNCS="${BATS_FILE_TMPDIR}/configure_funcs.sh"

    # Remove:
    #   • "set -e" (would terminate the sourcing shell on any command failure)
    #   • The final comment "# Run main function" and the call "main "$@""
    # Everything else — variable defaults and function definitions — is kept.
    grep -v '^set -e$' "${CONFIGURE_SH}" | head -n -2 > "${CONFIGURE_FUNCS}"
}

# =============================================================================
# Per-test setup: build a stub directory prepended to PATH so that external
# commands called by configure.sh functions can be intercepted.
# =============================================================================

setup() {
    _STUBS="${BATS_TEST_TMPDIR}/stubs"
    mkdir -p "${_STUBS}"
    export PATH="${_STUBS}:${PATH}"

    # ── curl stub ────────────────────────────────────────────────────────────
    # Behaviour:
    #   • Returns "200" when invoked with -w "%{http_code}" so that
    #     wait_for_service() is satisfied.
    #   • Appends the value of the -d argument (JSON body) to curl_posts so
    #     tests can assert what was sent.
    #   • Returns a POST-response JSON for -X POST calls.
    #   • Returns a GET-response JSON containing "id" and "path" fields for
    #     all other calls (quality-profiles, root-folder lookups).
    cat > "${_STUBS}/curl" << 'STUB'
#!/bin/bash
is_post=false
prev_arg=""
for arg in "$@"; do
    if [[ "$prev_arg" == "-X" && "$arg" == "POST" ]];   then is_post=true;     fi
    if [[ "$prev_arg" == "-w" && "$arg" == "%{http_code}" ]]; then
        printf "200"
        exit 0
    fi
    if [[ "$prev_arg" == "-d" ]]; then
        echo "$arg" >> "${BATS_TEST_TMPDIR}/curl_posts"
    fi
    prev_arg="$arg"
done
if [[ "$is_post" == "true" ]]; then
    echo '{"id":1}'
else
    # Satisfy both quality-profile (needs "id") and root-folder (needs "path")
    echo '[{"id":1,"name":"Any","path":"/movies"}]'
fi
STUB
    chmod +x "${_STUBS}/curl"

    # ── docker stub ──────────────────────────────────────────────────────────
    cat > "${_STUBS}/docker" << 'STUB'
#!/bin/bash
# Simulate qBittorrent log output used by get_qbittorrent_password()
echo "A temporary password is provided for this session: TestPass123"
STUB
    chmod +x "${_STUBS}/docker"

    # ── Source function definitions ──────────────────────────────────────────
    # shellcheck disable=SC1090  # reason: dynamic path set by setup_file
    source "${CONFIGURE_FUNCS}"

    # Reset capture file for each test
    rm -f "${BATS_TEST_TMPDIR}/curl_posts"
}

# =============================================================================
# ── Section 1: Env var declarations (static grep tests) ──────────────────────
# Each test performs a targeted grep on configure.sh to confirm the required
# variable is declared with the correct default value.
# =============================================================================

@test "configure.sh declares RADARR_PORT with default 7878" {
    grep -qE 'RADARR_PORT=.*7878' "${CONFIGURE_SH}"
}

@test "configure.sh declares SONARR_PORT with default 8989" {
    grep -qE 'SONARR_PORT=.*8989' "${CONFIGURE_SH}"
}

@test "configure.sh declares WAIT_MAX_ATTEMPTS with default 30" {
    grep -qE 'WAIT_MAX_ATTEMPTS=.*30' "${CONFIGURE_SH}"
}

@test "configure.sh declares WAIT_RETRY_SECS with default 2" {
    grep -qE 'WAIT_RETRY_SECS=.*2' "${CONFIGURE_SH}"
}

# =============================================================================
# ── Section 2: No inline port literals in Overseerr JSON bodies ──────────────
# Verify that the literal "port": 7878 / "port": 8989 strings no longer exist
# in configure.sh after the implementation is applied.
# =============================================================================

@test "configure.sh has no literal \"port\": 7878 in Overseerr JSON body" {
    # The file stores escaped quotes as \" — use fixed-string matching (-F).
    # This pattern only matches the JSON "port" field, not URL defaults.
    run grep -cF '\"port\": 7878' "${CONFIGURE_SH}"
    [ "$output" -eq 0 ]
}

@test "configure.sh has no literal \"port\": 8989 in Overseerr JSON body" {
    run grep -cF '\"port\": 8989' "${CONFIGURE_SH}"
    [ "$output" -eq 0 ]
}

@test "add_radarr_to_overseerr() body references RADARR_PORT variable" {
    local fn_body
    fn_body=$(awk '/^add_radarr_to_overseerr\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
        "${CONFIGURE_SH}")
    echo "${fn_body}" | grep -q 'RADARR_PORT'
}

@test "add_sonarr_to_overseerr() body references SONARR_PORT variable" {
    local fn_body
    fn_body=$(awk '/^add_sonarr_to_overseerr\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
        "${CONFIGURE_SH}")
    echo "${fn_body}" | grep -q 'SONARR_PORT'
}

# =============================================================================
# ── Section 3: wait_for_service retry configuration (static grep tests) ───────
# =============================================================================

@test "wait_for_service() references WAIT_MAX_ATTEMPTS — not a bare literal 30" {
    local fn_body
    fn_body=$(awk '/^wait_for_service\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
        "${CONFIGURE_SH}")
    echo "${fn_body}" | grep -q 'WAIT_MAX_ATTEMPTS'
}

@test "wait_for_service() references WAIT_RETRY_SECS — not a bare 'sleep 2'" {
    local fn_body
    fn_body=$(awk '/^wait_for_service\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
        "${CONFIGURE_SH}")
    echo "${fn_body}" | grep -q 'WAIT_RETRY_SECS'
}

@test "wait_for_service() does not contain hard-coded max_attempts=30 literal" {
    local fn_body
    fn_body=$(awk '/^wait_for_service\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
        "${CONFIGURE_SH}")
    # Ensure the literal assignment without a variable reference is absent
    run bash -c 'echo "${1}" | grep -cE "max_attempts=30[^$]"' -- "${fn_body}"
    [ "$output" -eq 0 ]
}

@test "wait_for_service() does not contain hard-coded 'sleep 2' literal" {
    local fn_body
    fn_body=$(awk '/^wait_for_service\(\)/{p=1} p{print} /^\}$/{if(p){p=0;exit}}' \
        "${CONFIGURE_SH}")
    run bash -c 'echo "${1}" | grep -cE "sleep 2$"' -- "${fn_body}"
    [ "$output" -eq 0 ]
}

# =============================================================================
# ── Section 4: Behavioural tests — runtime JSON payload assertions ────────────
# These tests actually call the functions with a stubbed curl and verify that
# the JSON body sent to Overseerr contains the expected port value.
# =============================================================================

@test "add_radarr_to_overseerr sends custom RADARR_PORT in Overseerr JSON payload" {
    export RADARR_PORT=29878
    export RADARR_HOST="radarr"
    export RADARR_URL="http://localhost:29878"
    export OVERSEERR_URL="http://localhost:5055"

    add_radarr_to_overseerr "fake-radarr-api-key" "fake-overseerr-api-key"

    # The JSON body logged by our curl stub must contain the custom port
    [ -f "${BATS_TEST_TMPDIR}/curl_posts" ]
    grep -q '"port":.*29878' "${BATS_TEST_TMPDIR}/curl_posts"
}

# Acceptance criterion from the work item:
#   Given SONARR_PORT is set to 29989
#   When configure.sh runs
#   Then the Overseerr sonarr config body sends port 29989
@test "add_sonarr_to_overseerr sends SONARR_PORT=29989 to Overseerr — acceptance criterion" {
    # Given
    export SONARR_PORT=29989
    export SONARR_HOST="sonarr"
    export SONARR_URL="http://localhost:29989"
    export OVERSEERR_URL="http://localhost:5055"

    # When
    add_sonarr_to_overseerr "fake-sonarr-api-key" "fake-overseerr-api-key"

    # Then
    [ -f "${BATS_TEST_TMPDIR}/curl_posts" ]
    grep -q '"port":.*29989' "${BATS_TEST_TMPDIR}/curl_posts"
}

@test "add_radarr_to_overseerr sends default port 7878 when RADARR_PORT is unset" {
    unset RADARR_PORT
    export RADARR_HOST="radarr"
    export RADARR_URL="http://localhost:7878"
    export OVERSEERR_URL="http://localhost:5055"

    # Re-source so configure.sh's default assignment (RADARR_PORT=${RADARR_PORT:-7878}) takes effect
    # shellcheck disable=SC1090  # reason: dynamic path set by setup_file
    source "${CONFIGURE_FUNCS}"

    add_radarr_to_overseerr "fake-radarr-api-key" "fake-overseerr-api-key"

    [ -f "${BATS_TEST_TMPDIR}/curl_posts" ]
    grep -q '"port":.*7878' "${BATS_TEST_TMPDIR}/curl_posts"
}

@test "add_sonarr_to_overseerr sends default port 8989 when SONARR_PORT is unset" {
    unset SONARR_PORT
    export SONARR_HOST="sonarr"
    export SONARR_URL="http://localhost:8989"
    export OVERSEERR_URL="http://localhost:5055"

    # Re-source so configure.sh's default assignment (SONARR_PORT=${SONARR_PORT:-8989}) takes effect
    # shellcheck disable=SC1090  # reason: dynamic path set by setup_file
    source "${CONFIGURE_FUNCS}"

    add_sonarr_to_overseerr "fake-sonarr-api-key" "fake-overseerr-api-key"

    [ -f "${BATS_TEST_TMPDIR}/curl_posts" ]
    grep -q '"port":.*8989' "${BATS_TEST_TMPDIR}/curl_posts"
}
