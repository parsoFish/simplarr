#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Test-VpnContainerWiring.Tests.ps1
# =============================================================================
# TDD Pester specification for Phase 10 (VPN Container Wiring) of test.ps1.
# Written BEFORE Phase 10 exists — tests in Phases 3–5 are expected to fail
# until a developer adds Phase 10 to dev-testing/test.ps1.
#
# Mirrors: dev-testing/test_vpn_wiring.sh (Bash counterpart)
#
# Phases:
#   1 — File existence and compose VPN documentation preconditions
#   2 — docker compose config resolution of a VPN overlay (integration)
#   3 — test.ps1 Phase 10 content assertions  ← fail until Phase 10 added
#   4 — TUN guard: Write-Skip emitted when /dev/net/tun is absent
#   5 — VPN connectivity: always Write-Skip 'Real VPN credentials required'
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-VpnContainerWiring.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
#   Docker with Compose v2 plugin (for Phase 2 integration tests)
# =============================================================================

# ---------------------------------------------------------------------------
# BeforeAll — runs once before any tests execute (Execution phase)
# Sets up file paths, reads cached content, and probes docker availability.
# ---------------------------------------------------------------------------

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:TestPs1  = Join-Path $PSScriptRoot 'test.ps1'
    $script:Unified  = Join-Path $script:RepoRoot 'docker-compose-unified.yml'
    $script:EnvVpn   = Join-Path $script:RepoRoot '.env.vpn.example'

    # Cache file contents once to avoid repeated I/O during tests
    $script:TestPs1Content = if (Test-Path $script:TestPs1) {
        Get-Content -Raw $script:TestPs1
    } else { $null }

    $script:UnifiedContent = if (Test-Path $script:Unified) {
        Get-Content -Raw $script:Unified
    } else { $null }

    # Probe docker compose availability
    $script:DockerAvailable = $false
    try {
        $null = docker compose version 2>&1
        $script:DockerAvailable = ($LASTEXITCODE -eq 0)
    } catch {
        $script:DockerAvailable = $false
    }

    # Supply env vars required by compose files for variable interpolation
    if ($script:DockerAvailable) {
        $env:PUID                  = '1000'
        $env:PGID                  = '1000'
        $env:TZ                    = 'UTC'
        $env:PLEX_CLAIM            = 'claim-test'
        $env:DOCKER_CONFIG         = Join-Path ([System.IO.Path]::GetTempPath()) 'simplarr-vpn-wiring-config'
        $env:DOCKER_MEDIA          = Join-Path ([System.IO.Path]::GetTempPath()) 'simplarr-vpn-wiring-media'
        $env:NAS_IP                = '192.168.1.100'
        $env:VPN_SERVICE_PROVIDER  = 'mullvad'
        $env:VPN_TYPE              = 'openvpn'
        $env:OPENVPN_USER          = 'test-user'
        $env:OPENVPN_PASSWORD      = 'test-password'
        $env:WIREGUARD_PRIVATE_KEY = 'test-key'
        $env:WIREGUARD_ADDRESSES   = '10.64.0.1/32'
        $env:VPN_SERVER_COUNTRIES  = 'Netherlands'
    }
}

AfterAll {
    $varsToRemove = @(
        'PUID', 'PGID', 'TZ', 'PLEX_CLAIM', 'DOCKER_CONFIG', 'DOCKER_MEDIA',
        'NAS_IP', 'VPN_SERVICE_PROVIDER', 'VPN_TYPE', 'OPENVPN_USER',
        'OPENVPN_PASSWORD', 'WIREGUARD_PRIVATE_KEY', 'WIREGUARD_ADDRESSES',
        'VPN_SERVER_COUNTRIES'
    )
    foreach ($var in $varsToRemove) {
        Remove-Item "Env:$var" -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# Phase 1 — File existence and compose VPN documentation preconditions
# These tests confirm the static inputs that Phase 10 will operate on exist.
# =============================================================================

Describe 'Phase 1 — Required files exist' {

    It 'docker-compose-unified.yml exists at repo root' {
        $script:Unified | Should -Exist
    }

    It 'dev-testing/test.ps1 exists' {
        $script:TestPs1 | Should -Exist
    }

    It '.env.vpn.example exists at repo root' {
        $script:EnvVpn | Should -Exist
    }
}

Describe 'Phase 1 — docker-compose-unified.yml documents VPN wiring in comments' {
    # The commented gluetun + qbittorrent VPN override blocks must be present
    # in docker-compose-unified.yml so users can uncomment them. Phase 10 of
    # test.ps1 validates these blocks by parsing docker compose config output.

    It 'contains a commented gluetun service block' {
        $script:UnifiedContent | Should -Not -BeNullOrEmpty `
            -Because 'docker-compose-unified.yml must exist and be readable'
        $script:UnifiedContent | Should -Match 'gluetun' `
            -Because 'docker-compose-unified.yml must document the gluetun VPN container'
    }

    It 'documents network_mode: service:gluetun in the qbittorrent VPN override comments' {
        $script:UnifiedContent | Should -Not -BeNullOrEmpty
        $script:UnifiedContent | Should -Match 'network_mode.*service:gluetun' `
            -Because 'docker-compose-unified.yml must document qbittorrent using gluetun network namespace'
    }

    It 'documents port 8080:8080 under the commented gluetun service' {
        $script:UnifiedContent | Should -Not -BeNullOrEmpty
        $script:UnifiedContent | Should -Match '8080:8080' `
            -Because 'gluetun must own port 8080 (qBittorrent WebUI) in the VPN layout'
    }

    It 'documents port 6881:6881 under the commented gluetun service' {
        $script:UnifiedContent | Should -Not -BeNullOrEmpty
        $script:UnifiedContent | Should -Match '6881:6881' `
            -Because 'gluetun must own port 6881 (torrent traffic) in the VPN layout'
    }

    It 'documents depends_on gluetun with condition: service_healthy' {
        $script:UnifiedContent | Should -Not -BeNullOrEmpty
        $script:UnifiedContent | Should -Match 'service_healthy' `
            -Because 'qbittorrent must not start before gluetun tunnel is established'
    }

    It 'uses a pinned gluetun image tag, not :latest' {
        $script:UnifiedContent | Should -Not -BeNullOrEmpty

        $gluetunLatestLines = ($script:UnifiedContent -split '\r?\n') |
            Where-Object { $_ -match 'gluetun:latest' }

        $gluetunLatestLines | Should -BeNullOrEmpty `
            -Because 'gluetun image must pin a specific version tag so users can safely uncomment it'
    }
}

# =============================================================================
# Phase 2 — docker compose config resolves a VPN overlay correctly
#
# Creates a minimal self-contained VPN compose overlay (no env var references)
# mirroring what a user sees after uncommenting the gluetun blocks, then runs
# docker compose config on it and asserts the resolved output.
# Tests are skipped automatically when Docker is not available.
# =============================================================================

Describe 'Phase 2 — docker compose config VPN overlay resolution' {

    BeforeAll {
        # Minimal VPN overlay with hard-coded values — avoids env var
        # interpolation issues and mirrors the commented gluetun + qbittorrent
        # VPN override blocks in docker-compose-unified.yml.
        $script:VpnOverlayYaml = @'
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
'@

        $script:VpnTmpDir        = $null
        $script:VpnConfigOutput  = @()
        $script:VpnConfigSuccess = $false

        if ($script:DockerAvailable) {
            $script:VpnTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) `
                "simplarr-vpn-wiring-$(Get-Random)"
            $null = New-Item -ItemType Directory -Path $script:VpnTmpDir -Force

            $overlayPath = Join-Path $script:VpnTmpDir 'vpn-wiring.yml'
            $script:VpnOverlayYaml | Set-Content -Path $overlayPath -Encoding UTF8

            $script:VpnConfigOutput  = docker compose -f $overlayPath config 2>&1
            $script:VpnConfigSuccess = ($LASTEXITCODE -eq 0)
        }
    }

    AfterAll {
        if ($null -ne $script:VpnTmpDir -and (Test-Path $script:VpnTmpDir)) {
            Remove-Item -Recurse -Force $script:VpnTmpDir -ErrorAction SilentlyContinue
        }
    }

    It 'VPN overlay YAML parses cleanly under docker compose config' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'docker compose is not available'
            return
        }
        $outputText = $script:VpnConfigOutput -join "`n"
        $script:VpnConfigSuccess | Should -BeTrue `
            -Because "VPN overlay YAML must parse without errors.`nOutput: $outputText"
    }

    It 'resolved config shows qbittorrent with network_mode: service:gluetun' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'docker compose is not available'
            return
        }
        if (-not $script:VpnConfigSuccess) {
            Set-ItResult -Skipped -Because 'docker compose config failed — see prior test'
            return
        }
        $configText = $script:VpnConfigOutput -join "`n"
        $configText | Should -Match 'network_mode:\s*service:gluetun' `
            -Because 'qbittorrent must share gluetun network namespace in resolved YAML'
    }

    It 'resolved config shows port 8080 owned by gluetun (qBittorrent WebUI)' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'docker compose is not available'
            return
        }
        if (-not $script:VpnConfigSuccess) {
            Set-ItResult -Skipped -Because 'docker compose config failed — see prior test'
            return
        }
        $configText = $script:VpnConfigOutput -join "`n"
        # docker compose config normalises ports to 'published: "8080"' or '8080:8080'
        $hasPort8080 = ($configText -match 'published:\s*"?8080"?') -or
                       ($configText -match '8080:8080')
        $hasPort8080 | Should -BeTrue `
            -Because 'port 8080 must appear under gluetun in resolved YAML (qbittorrent has none when VPN-wired)'
    }

    It 'resolved config shows port 6881 owned by gluetun (torrent traffic)' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'docker compose is not available'
            return
        }
        if (-not $script:VpnConfigSuccess) {
            Set-ItResult -Skipped -Because 'docker compose config failed — see prior test'
            return
        }
        $configText = $script:VpnConfigOutput -join "`n"
        $hasPort6881 = ($configText -match 'published:\s*"?6881"?') -or
                       ($configText -match '6881:6881')
        $hasPort6881 | Should -BeTrue `
            -Because 'port 6881 must appear under gluetun in resolved YAML'
    }

    It 'resolved config shows qbittorrent depends_on gluetun with condition: service_healthy' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'docker compose is not available'
            return
        }
        if (-not $script:VpnConfigSuccess) {
            Set-ItResult -Skipped -Because 'docker compose config failed — see prior test'
            return
        }
        $configText = $script:VpnConfigOutput -join "`n"
        $configText | Should -Match 'condition:\s*service_healthy' `
            -Because 'qbittorrent must not start before the gluetun VPN tunnel is established'
    }
}

# =============================================================================
# Phase 3 — test.ps1 must contain Phase 10 VPN Container Wiring assertions
#
# These tests FAIL until a developer adds Phase 10 to dev-testing/test.ps1.
# They specify the exact patterns the implementation must include.
# =============================================================================

Describe 'Phase 3 — test.ps1 Phase 10 content assertions (fail until Phase 10 added)' {

    It 'test.ps1 contains a Phase 10 VPN Container Wiring section' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        $script:TestPs1Content | Should -Match 'Phase 10' `
            -Because 'test.ps1 must have a Phase 10 VPN Container Wiring section to mirror Bash test.sh'
    }

    It 'test.ps1 Phase 10 creates a temporary VPN overlay YAML for docker compose config' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        # Phase 10a writes a temporary compose file and runs docker compose config on it
        $script:TestPs1Content | Should -Match 'gluetun.*\.yml|vpn.*wiring|vpn.*overlay' `
            -Because 'Phase 10a must create a VPN overlay YAML and parse its docker compose config output'
    }

    It 'test.ps1 Phase 10 asserts qbittorrent carries network_mode: service:gluetun' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        $script:TestPs1Content | Should -Match 'network_mode.*service:gluetun' `
            -Because 'Phase 10a must assert qbittorrent uses network_mode: service:gluetun'
    }

    It 'test.ps1 Phase 10 asserts gluetun owns port 8080' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        # The Pass/Fail messages for port 8080 must reference gluetun ownership
        $script:TestPs1Content | Should -Match 'gluetun.*8080|8080.*gluetun|port 8080' `
            -Because 'Phase 10a must assert port 8080 appears under gluetun (qBittorrent WebUI)'
    }

    It 'test.ps1 Phase 10 asserts gluetun owns port 6881' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        $script:TestPs1Content | Should -Match 'gluetun.*6881|6881.*gluetun|port 6881' `
            -Because 'Phase 10a must assert port 6881 appears under gluetun (torrent traffic)'
    }

    It 'test.ps1 Phase 10 guards runtime assertions with a /dev/net/tun existence check' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        # Phase 10b must use Test-Path to check for the TUN device before starting containers
        $script:TestPs1Content | Should -Match 'Test-Path.*tun|dev.*net.*tun' `
            -Because 'Phase 10b must guard runtime assertions with Test-Path for /dev/net/tun'
    }

    It 'test.ps1 Phase 10b emits Write-Skip with a TUN-related message when device is absent' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        $script:TestPs1Content | Should -Match 'Write-Skip.*[Tt][Uu][Nn]' `
            -Because 'Phase 10b must Write-Skip each runtime test with a TUN-related message when /dev/net/tun is absent'
    }

    It 'test.ps1 Phase 10c emits Write-Skip with "Real VPN credentials required"' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        $script:TestPs1Content | Should -Match "Write-Skip.*Real VPN credentials" `
            -Because 'Phase 10c VPN connectivity check must always Write-Skip — it cannot be automated'
    }

    It 'test.ps1 header comment lists Phase 10 VPN Container Wiring' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        # The header block at the top of test.ps1 should document all phases including 10
        $script:TestPs1Content | Should -Match '10.*VPN|VPN.*Container.*Wiring' `
            -Because 'test.ps1 header must be updated to document Phase 10 VPN Container Wiring'
    }
}

# =============================================================================
# Phase 4 — TUN guard: Write-Skip emitted when /dev/net/tun is absent
#
# Verifies that the implementation guards runtime container assertions with
# a Test-Path check and emits Write-Skip for each guarded test.
# Tests remain in Phase 3 pattern (content checks) since we cannot safely
# invoke test.ps1 as a subprocess in all environments.
# =============================================================================

Describe 'Phase 4 — TUN device guard: runtime assertions skipped when /dev/net/tun absent' {

    It 'test.ps1 references the /dev/net/tun device path in Phase 10 context' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        $script:TestPs1Content | Should -Match '/dev/net/tun' `
            -Because 'Phase 10b must explicitly reference /dev/net/tun to guard runtime container tests'
    }

    It 'test.ps1 uses Test-Path to check TUN device existence before runtime assertions' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        # PowerShell idiom for checking device existence
        $script:TestPs1Content | Should -Match 'Test-Path.*tun' `
            -Because 'Phase 10b must use Test-Path (not [System.IO.File]::Exists) to check TUN device'
    }

    It 'test.ps1 Phase 10b emits at least one Write-Skip for the gluetun container start test' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        # Phase 10b has two guarded tests: container start + docker inspect State.Status=running
        # The skip messages must mention the TUN device or the container start
        $hasTunSkip = $script:TestPs1Content -match 'Write-Skip.*[Tt][Uu][Nn]' -or
                      $script:TestPs1Content -match 'Write-Skip.*gluetun.*start|Write-Skip.*container.*start'
        $hasTunSkip | Should -BeTrue `
            -Because 'Phase 10b must Write-Skip for gluetun container start when /dev/net/tun is absent'
    }
}

# =============================================================================
# Phase 5 — VPN connectivity: always Write-Skip 'Real VPN credentials required'
#
# Phase 10c must be unconditional — VPN connectivity cannot be automated in CI
# because it requires genuine VPN provider credentials.
# =============================================================================

Describe 'Phase 5 — VPN connectivity always Write-Skip with clear message' {

    It 'test.ps1 Phase 10c emits Write-Skip for VPN connectivity unconditionally' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        # The Write-Skip call must not be inside a conditional block guarded by TUN
        # (it must run regardless). We verify the message exists in the file.
        $script:TestPs1Content | Should -Match "Write-Skip.*Real VPN credentials" `
            -Because 'Phase 10c must always Write-Skip VPN connectivity — real credentials cannot be supplied in CI'
    }

    It 'VPN connectivity skip message is "Real VPN credentials required"' {
        $script:TestPs1Content | Should -Not -BeNullOrEmpty
        $script:TestPs1Content | Should -Match 'Real VPN credentials required' `
            -Because 'The VPN connectivity skip message must be exactly "Real VPN credentials required"'
    }
}

# =============================================================================
# Phase 5 (aggregate) — PSScriptAnalyzer compliance of test.ps1
#
# Ensures that whatever Phase 10 code the developer adds to test.ps1 does
# not introduce PSScriptAnalyzer warnings or errors.
# =============================================================================

Describe 'Phase 5 — test.ps1 passes PSScriptAnalyzer after Phase 10 is added' {

    BeforeAll {
        $script:AnalyzerAvailable = $false
        $script:AnalyzerResults   = @()

        if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
            Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
            $script:AnalyzerAvailable = $true

            if ($script:AnalyzerAvailable -and (Test-Path $script:TestPs1)) {
                $script:AnalyzerResults = Invoke-ScriptAnalyzer `
                    -Path $script:TestPs1 `
                    -Severity @('Warning', 'Error') `
                    -ErrorAction SilentlyContinue
            }
        }
    }

    It 'test.ps1 produces zero PSScriptAnalyzer warnings or errors' {
        if (-not $script:AnalyzerAvailable) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer module is not installed'
            return
        }
        $report = $script:AnalyzerResults |
            ForEach-Object { "  [$($_.Severity)] line $($_.Line): $($_.RuleName) — $($_.Message)" }
        $script:AnalyzerResults | Should -BeNullOrEmpty `
            -Because (
                "test.ps1 must have zero PSScriptAnalyzer findings after Phase 10 is added. " +
                "Found $($script:AnalyzerResults.Count) issue(s):`n" + ($report -join "`n")
            )
    }
}
