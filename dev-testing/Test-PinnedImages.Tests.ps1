#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Pinned Docker Image Version Tests (Pester)
# =============================================================================
# Verifies that all compose files, the homepage Dockerfile, and VERSIONS.md
# meet the pinned-image acceptance criteria:
#
#   1. Zero :latest tags on active (non-commented) image lines in all compose files
#   2. Commented-out services (gluetun, qbittorrent VPN override) also pinned
#   3. homepage/Dockerfile FROM line references a versioned nginx-alpine tag
#   4. VERSIONS.md documents every service with tag, release date, and URL
#   5. docker compose config --quiet succeeds on all three compose files
#   6. Same image uses the same tag across all files (no version drift)
#
# TDD: These tests are written BEFORE the implementation exists and MUST fail
# on the current codebase (all images use :latest, VERSIONS.md is absent).
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-PinnedImages.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
#   Docker with Compose v2 plugin (for Phases 5-6 integration tests)
# =============================================================================

# ---------------------------------------------------------------------------
# Script-scope data  -  defined OUTSIDE BeforeAll so they are available
# during Pester's Discovery phase when Describe/Context/It blocks are built.
# (Variables set inside BeforeAll are only available during Execution.)
# ---------------------------------------------------------------------------

# Compose file names (relative to repo root) used for foreach-generated tests
$script:ComposeFileNames = @(
    'docker-compose-unified.yml'
    'docker-compose-nas.yml'
    'docker-compose-pi.yml'
)

# Active (non-commented) services per compose file  -  image prefix keyed by service name
$script:UnifiedServices = [ordered]@{
    plex        = 'linuxserver/plex'
    qbittorrent = 'linuxserver/qbittorrent'
    radarr      = 'linuxserver/radarr'
    sonarr      = 'linuxserver/sonarr'
    prowlarr    = 'linuxserver/prowlarr'
    overseerr   = 'sctx/overseerr'
    tautulli    = 'linuxserver/tautulli'
    nginx       = 'nginx'
}
$script:NasServices = [ordered]@{
    plex        = 'linuxserver/plex'
    qbittorrent = 'linuxserver/qbittorrent'
}
$script:PiServices = [ordered]@{
    radarr    = 'linuxserver/radarr'
    sonarr    = 'linuxserver/sonarr'
    prowlarr  = 'linuxserver/prowlarr'
    tautulli  = 'linuxserver/tautulli'
    nginx     = 'nginx'
    overseerr = 'sctx/overseerr'
}

# Every image that must appear in VERSIONS.md
$script:AllImages = @(
    'linuxserver/plex'
    'linuxserver/qbittorrent'
    'linuxserver/radarr'
    'linuxserver/sonarr'
    'linuxserver/prowlarr'
    'sctx/overseerr'
    'linuxserver/tautulli'
    'nginx'
    'qmcgaw/gluetun'
)

# Images that appear in multiple compose files  -  must carry the same tag everywhere
$script:SharedImageFiles = @(
    @{ Image = 'linuxserver/radarr';      Files = @('docker-compose-unified.yml', 'docker-compose-pi.yml') }
    @{ Image = 'linuxserver/sonarr';      Files = @('docker-compose-unified.yml', 'docker-compose-pi.yml') }
    @{ Image = 'linuxserver/prowlarr';    Files = @('docker-compose-unified.yml', 'docker-compose-pi.yml') }
    @{ Image = 'sctx/overseerr';          Files = @('docker-compose-unified.yml', 'docker-compose-pi.yml') }
    @{ Image = 'linuxserver/tautulli';    Files = @('docker-compose-unified.yml', 'docker-compose-pi.yml') }
    @{ Image = 'nginx';                   Files = @('docker-compose-unified.yml', 'docker-compose-pi.yml') }
    @{ Image = 'linuxserver/plex';        Files = @('docker-compose-unified.yml', 'docker-compose-nas.yml') }
    @{ Image = 'linuxserver/qbittorrent'; Files = @('docker-compose-unified.yml', 'docker-compose-nas.yml') }
)

# ---------------------------------------------------------------------------
# Helper  -  asserts that all active image: lines for a given image prefix
# carry a version-like tag (not :latest, not missing).
# Must be defined at script scope so it is accessible in all test phases.
# ---------------------------------------------------------------------------

function Assert-ImageIsPinned {
    param(
        [string]$FileContent,
        [string]$ImagePrefix,
        [string]$ContextDescription
    )
    # A pinned tag satisfies at least one condition:
    #   - Contains a numeric semver segment:  name:1.2  name:1.2.3  name:v1.2
    #   - Is a SHA digest reference:          name@sha256:<hex>
    # It must NOT be the floating alias :latest

    $imageLines = ($FileContent -split '\r?\n') |
        Where-Object { $_ -notmatch '^\s*#' } |
        Where-Object { $_ -match "\bimage:\s*${ImagePrefix}[:\s@]" }

    $imageLines | Should -Not -BeNullOrEmpty `
        -Because "At least one active image: line for '$ImagePrefix' must exist in $ContextDescription"

    foreach ($line in $imageLines) {
        if ($line -match "\bimage:\s*\S+:(.+)$") {
            $tag = $Matches[1].Trim()
            $tag | Should -Not -Match '^latest$' `
                -Because "$ContextDescription '$ImagePrefix': must not use :latest (found '$tag')"
            $tag | Should -Not -Match '^stable$' `
                -Because "$ContextDescription '$ImagePrefix': must not use :stable (found '$tag')"
            ($tag -match '\d+\.\d+' -or $tag -match '^v\d+' -or $tag -match '@sha256:') |
                Should -BeTrue `
                -Because (
                    "$ContextDescription '$ImagePrefix': tag '$tag' must include a numeric version " +
                    "(e.g. 1.2.3 or v3.39.1) or a sha256 digest"
                )
        } elseif ($line -match '@sha256:') {
            # Digest-pinned reference  -  always acceptable, no further checks needed
        } else {
            # Bare image name with no tag at all is also unacceptable
            $line | Should -Match ':\S+' `
                -Because "$ContextDescription '$ImagePrefix': image line must include an explicit version tag: $line"
        }
    }
}

# ---------------------------------------------------------------------------
# BeforeAll  -  runs once before any tests execute (Execution phase)
# Loads file paths and caches file contents for all test blocks.
# ---------------------------------------------------------------------------

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    $script:ComposePaths = [ordered]@{
        'docker-compose-unified.yml' = Join-Path $script:RepoRoot 'docker-compose-unified.yml'
        'docker-compose-nas.yml'     = Join-Path $script:RepoRoot 'docker-compose-nas.yml'
        'docker-compose-pi.yml'      = Join-Path $script:RepoRoot 'docker-compose-pi.yml'
    }
    $script:HomepageDockerfile = Join-Path $script:RepoRoot 'homepage' 'Dockerfile'
    $script:VersionsMd         = Join-Path $script:RepoRoot 'VERSIONS.md'

    # Cache raw file contents to avoid repeated disk I/O during tests
    $script:ComposeContent = @{}
    foreach ($name in $script:ComposePaths.Keys) {
        $path = $script:ComposePaths[$name]
        $script:ComposeContent[$name] = if (Test-Path $path) { Get-Content -Raw $path } else { $null }
    }

    $script:DockerfileContent = if (Test-Path $script:HomepageDockerfile) {
        Get-Content -Raw $script:HomepageDockerfile
    } else { $null }

    $script:VersionsMdContent = if (Test-Path $script:VersionsMd) {
        Get-Content -Raw $script:VersionsMd
    } else { $null }
}

# =============================================================================
# Phase 1  -  Compose files: zero :latest tags on active image lines
# =============================================================================

Describe 'Compose files  -  zero :latest tags on active image lines' {

    foreach ($fileName in $script:ComposeFileNames) {
        Context $fileName {
            It "should have no active (non-commented) lines containing :latest in $fileName" {
                $content = $script:ComposeContent[$fileName]
                $content | Should -Not -BeNullOrEmpty `
                    -Because "$fileName must exist and be readable"

                # Lines whose first non-whitespace character is '#' are YAML comments
                $latestLines = ($content -split '\r?\n') |
                    Where-Object { $_ -notmatch '^\s*#' } |
                    Where-Object { $_ -match '\bimage:\s*\S+:latest\b' }

                $report = $latestLines -join "`n"
                $latestLines | Should -BeNullOrEmpty `
                    -Because (
                        "All active image: entries in $fileName must use pinned version tags, " +
                        "not :latest. Offending line(s):`n$report"
                    )
            }
        }
    }
}

# =============================================================================
# Phase 2  -  Compose files: each service has a version-pinned image tag
# =============================================================================

Describe 'Compose files  -  each service image has a pinned version tag' {

    Context 'docker-compose-unified.yml' {
        foreach ($serviceName in $script:UnifiedServices.Keys) {
            $imagePrefix = $script:UnifiedServices[$serviceName]
            It "should have a pinned version tag for $serviceName ($imagePrefix)" {
                $content = $script:ComposeContent['docker-compose-unified.yml']
                $content | Should -Not -BeNullOrEmpty `
                    -Because 'docker-compose-unified.yml must exist and be readable'
                Assert-ImageIsPinned -FileContent $content `
                    -ImagePrefix $imagePrefix `
                    -ContextDescription 'docker-compose-unified.yml'
            }
        }
    }

    Context 'docker-compose-nas.yml' {
        foreach ($serviceName in $script:NasServices.Keys) {
            $imagePrefix = $script:NasServices[$serviceName]
            It "should have a pinned version tag for $serviceName ($imagePrefix)" {
                $content = $script:ComposeContent['docker-compose-nas.yml']
                $content | Should -Not -BeNullOrEmpty `
                    -Because 'docker-compose-nas.yml must exist and be readable'
                Assert-ImageIsPinned -FileContent $content `
                    -ImagePrefix $imagePrefix `
                    -ContextDescription 'docker-compose-nas.yml'
            }
        }
    }

    Context 'docker-compose-pi.yml' {
        foreach ($serviceName in $script:PiServices.Keys) {
            $imagePrefix = $script:PiServices[$serviceName]
            It "should have a pinned version tag for $serviceName ($imagePrefix)" {
                $content = $script:ComposeContent['docker-compose-pi.yml']
                $content | Should -Not -BeNullOrEmpty `
                    -Because 'docker-compose-pi.yml must exist and be readable'
                Assert-ImageIsPinned -FileContent $content `
                    -ImagePrefix $imagePrefix `
                    -ContextDescription 'docker-compose-pi.yml'
            }
        }
    }
}

# =============================================================================
# Phase 3  -  Commented-out services: gluetun and qbittorrent VPN overrides
# =============================================================================

Describe 'Compose files  -  commented-out services also have pinned tags' {
    # Gluetun and the qbittorrent VPN-override block are commented out for
    # optional use. They must still carry pinned tags so users can safely
    # uncomment them without accidentally pulling a floating :latest image.

    Context 'docker-compose-unified.yml  -  commented gluetun' {
        It 'should not contain qmcgaw/gluetun:latest in the commented-out section' {
            $content = $script:ComposeContent['docker-compose-unified.yml']
            $content | Should -Not -BeNullOrEmpty

            $commentedGluetunLatest = ($content -split '\r?\n') |
                Where-Object { $_ -match '^\s*#.*image:\s*qmcgaw/gluetun:latest' }

            $report = $commentedGluetunLatest -join "`n"
            $commentedGluetunLatest | Should -BeNullOrEmpty `
                -Because (
                    "Commented-out gluetun service in docker-compose-unified.yml " +
                    "must not use :latest (so users can safely uncomment it). Found:`n$report"
                )
        }

        It 'should have qmcgaw/gluetun with a pinned version tag in the commented-out section' {
            $content = $script:ComposeContent['docker-compose-unified.yml']
            $content | Should -Not -BeNullOrEmpty

            $commentedGluetunLines = ($content -split '\r?\n') |
                Where-Object { $_ -match '^\s*#.*image:\s*qmcgaw/gluetun:' }

            $commentedGluetunLines | Should -Not -BeNullOrEmpty `
                -Because 'docker-compose-unified.yml must retain a commented gluetun image line with a pinned tag'

            foreach ($line in $commentedGluetunLines) {
                $line | Should -Match 'qmcgaw/gluetun:[v]?\d+' `
                    -Because "Commented gluetun image line must reference a specific version (e.g. v3.39.1): $line"
            }
        }

        It 'should not contain linuxserver/qbittorrent:latest in the commented VPN override block' {
            $content = $script:ComposeContent['docker-compose-unified.yml']
            $content | Should -Not -BeNullOrEmpty

            $commentedQbLatest = ($content -split '\r?\n') |
                Where-Object { $_ -match '^\s*#.*image:\s*linuxserver/qbittorrent:latest' }

            $report = $commentedQbLatest -join "`n"
            $commentedQbLatest | Should -BeNullOrEmpty `
                -Because (
                    "Commented qbittorrent VPN override in docker-compose-unified.yml " +
                    "must not use :latest. Found:`n$report"
                )
        }
    }

    Context 'docker-compose-nas.yml  -  commented gluetun' {
        It 'should not contain qmcgaw/gluetun:latest in the commented-out section' {
            $content = $script:ComposeContent['docker-compose-nas.yml']
            $content | Should -Not -BeNullOrEmpty

            $commentedGluetunLatest = ($content -split '\r?\n') |
                Where-Object { $_ -match '^\s*#.*image:\s*qmcgaw/gluetun:latest' }

            $report = $commentedGluetunLatest -join "`n"
            $commentedGluetunLatest | Should -BeNullOrEmpty `
                -Because (
                    "Commented-out gluetun service in docker-compose-nas.yml " +
                    "must not use :latest. Found:`n$report"
                )
        }

        It 'should have qmcgaw/gluetun with a pinned version tag in the commented-out section' {
            $content = $script:ComposeContent['docker-compose-nas.yml']
            $content | Should -Not -BeNullOrEmpty

            $commentedGluetunLines = ($content -split '\r?\n') |
                Where-Object { $_ -match '^\s*#.*image:\s*qmcgaw/gluetun:' }

            $commentedGluetunLines | Should -Not -BeNullOrEmpty `
                -Because 'docker-compose-nas.yml must retain a commented gluetun image line with a pinned tag'

            foreach ($line in $commentedGluetunLines) {
                $line | Should -Match 'qmcgaw/gluetun:[v]?\d+' `
                    -Because "Commented gluetun image line must reference a specific version (e.g. v3.39.1): $line"
            }
        }

        It 'should not contain linuxserver/qbittorrent:latest in the commented VPN override block' {
            $content = $script:ComposeContent['docker-compose-nas.yml']
            $content | Should -Not -BeNullOrEmpty

            $commentedQbLatest = ($content -split '\r?\n') |
                Where-Object { $_ -match '^\s*#.*image:\s*linuxserver/qbittorrent:latest' }

            $report = $commentedQbLatest -join "`n"
            $commentedQbLatest | Should -BeNullOrEmpty `
                -Because (
                    "Commented qbittorrent VPN override in docker-compose-nas.yml " +
                    "must not use :latest. Found:`n$report"
                )
        }
    }
}

# =============================================================================
# Phase 4  -  homepage/Dockerfile: pinned nginx-alpine base image
# =============================================================================

Describe 'homepage/Dockerfile  -  pinned nginx-alpine base image' {

    It 'should exist at homepage/Dockerfile' {
        $script:HomepageDockerfile | Should -Exist
    }

    It 'should not use FROM nginx:latest' {
        $script:DockerfileContent | Should -Not -BeNullOrEmpty `
            -Because 'homepage/Dockerfile must exist and be readable'

        ($script:DockerfileContent -split '\r?\n') |
            Where-Object { $_ -match '^\s*FROM\s+nginx:latest\b' } |
            Should -BeNullOrEmpty `
            -Because 'homepage/Dockerfile must not use the floating :latest tag'
    }

    It 'should not use bare FROM nginx:alpine (unversioned floating tag)' {
        $script:DockerfileContent | Should -Not -BeNullOrEmpty

        # "nginx:alpine" without a numeric nginx version is a floating tag  - 
        # it resolves to whatever the latest nginx-on-alpine happens to be.
        # Acceptable: nginx:1.25-alpine, nginx:1.27.4-alpine3.20
        # NOT acceptable: nginx:alpine  (no numeric version before -alpine)
        ($script:DockerfileContent -split '\r?\n') |
            Where-Object { $_ -match '^\s*FROM\s+nginx:alpine\s*$' } |
            Should -BeNullOrEmpty `
            -Because (
                'homepage/Dockerfile must pin a specific nginx version rather than the ' +
                'floating nginx:alpine tag. Use a tag like nginx:1.25-alpine or nginx:1.27.4-alpine3.20'
            )
    }

    It 'should use a versioned nginx-alpine tag containing a numeric nginx version' {
        $script:DockerfileContent | Should -Not -BeNullOrEmpty

        $fromLines = ($script:DockerfileContent -split '\r?\n') |
            Where-Object { $_ -match '^\s*FROM\s+nginx:' }

        $fromLines | Should -Not -BeNullOrEmpty `
            -Because 'homepage/Dockerfile must have a FROM nginx:<tag> line'

        foreach ($line in $fromLines) {
            # Tag must be numeric-version then -alpine, e.g. 1.25-alpine or 1.27.4-alpine3.20
            $line | Should -Match 'FROM\s+nginx:\d+\.\d+.*-alpine' `
                -Because (
                    "homepage/Dockerfile FROM line '$line' must reference a specific " +
                    "nginx version (e.g. nginx:1.25-alpine or nginx:1.27.4-alpine3.20)"
                )
        }
    }
}

# =============================================================================
# Phase 5  -  VERSIONS.md: existence, structure, and completeness
# =============================================================================

Describe 'VERSIONS.md  -  file existence and non-empty content' {

    It 'should exist at the repository root' {
        $script:VersionsMd | Should -Exist `
            -Because 'VERSIONS.md must be created to document all pinned image versions'
    }

    It 'should not be empty' {
        if (-not (Test-Path $script:VersionsMd)) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        $script:VersionsMdContent | Should -Not -BeNullOrEmpty `
            -Because 'VERSIONS.md must contain version documentation'
        $script:VersionsMdContent.Trim().Length | Should -BeGreaterThan 100 `
            -Because 'VERSIONS.md must have meaningful content (not just a heading)'
    }
}

Describe 'VERSIONS.md  -  all services are documented' {

    foreach ($image in $script:AllImages) {
        It "should document $image" {
            if ($null -eq $script:VersionsMdContent) {
                Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
                return
            }
            # Accept either the full image reference or just the short name
            $shortName = ($image -split '/')[-1]
            $found = ($script:VersionsMdContent -match [regex]::Escape($image)) -or
                     ($script:VersionsMdContent -match [regex]::Escape($shortName))
            $found | Should -BeTrue `
                -Because "VERSIONS.md must include an entry for '$image' (or its short name '$shortName')"
        }
    }
}

Describe 'VERSIONS.md  -  each entry has required fields' {

    It 'should include at least one numeric version tag (e.g. 1.2.3 or v3.39.1)' {
        if ($null -eq $script:VersionsMdContent) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        $script:VersionsMdContent | Should -Match '\d+\.\d+\.\d+' `
            -Because 'VERSIONS.md must list version tags containing numeric versions (e.g. 1.40.0)'
    }

    It 'should include release dates in ISO 8601 format (YYYY-MM-DD)' {
        if ($null -eq $script:VersionsMdContent) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        $script:VersionsMdContent | Should -Match '\b20\d{2}-\d{2}-\d{2}\b' `
            -Because 'VERSIONS.md must include release dates in YYYY-MM-DD format for each service'
    }

    It 'should include at least one upstream changelog or release URL (https://)' {
        if ($null -eq $script:VersionsMdContent) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        $script:VersionsMdContent | Should -Match 'https://' `
            -Because 'VERSIONS.md must include upstream release/changelog URLs'
    }

    It 'should include GitHub releases URLs for linuxserver/* images' {
        if ($null -eq $script:VersionsMdContent) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        $script:VersionsMdContent | Should -Match 'github\.com' `
            -Because 'VERSIONS.md must link to GitHub release pages (linuxserver images are on GitHub)'
    }

    It 'should document the gluetun VPN image (qmcgaw/gluetun) with a pinned tag' {
        if ($null -eq $script:VersionsMdContent) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        ($script:VersionsMdContent -match 'gluetun' -or $script:VersionsMdContent -match 'qmcgaw') |
            Should -BeTrue `
            -Because 'VERSIONS.md must document qmcgaw/gluetun so users know the pinned VPN image version'
    }

    It 'should contain a section explaining how to check for newer stable releases' {
        if ($null -eq $script:VersionsMdContent) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        # Accept any reasonable phrasing about checking/upgrading versions
        $hasUpdateSection = (
            $script:VersionsMdContent -imatch 'check.*newer' -or
            $script:VersionsMdContent -imatch 'how to.*update' -or
            $script:VersionsMdContent -imatch 'upgrading' -or
            $script:VersionsMdContent -imatch 'how to check' -or
            $script:VersionsMdContent -imatch 'checking.*version' -or
            $script:VersionsMdContent -imatch 'newer.*stable' -or
            $script:VersionsMdContent -imatch 'update.*image'
        )
        $hasUpdateSection | Should -BeTrue `
            -Because (
                'VERSIONS.md must include a note on how to check for newer stable releases, ' +
                'e.g. a "Checking for Updates" section'
            )
    }
}

# =============================================================================
# Phase 6  -  Cross-file consistency: same image uses identical tag everywhere
# =============================================================================

Describe 'Compose files  -  same image must use the same tag across all files' {
    # Prevents version drift: if radarr is 4.0.0 in unified but 3.9.0 in pi,
    # the split and unified deployments would run different software versions.

    foreach ($entry in $script:SharedImageFiles) {
        $image = $entry.Image
        $files = $entry.Files
        $label = "$image in $($files -join ' and ')"

        It "should use identical pinned tag for $label" {
            $tags = @{}
            foreach ($fileName in $files) {
                $content = $script:ComposeContent[$fileName]
                if ($null -eq $content) { continue }

                $line = ($content -split '\r?\n') |
                    Where-Object { $_ -notmatch '^\s*#' } |
                    Where-Object { $_ -match "\bimage:\s*${image}:" } |
                    Select-Object -First 1

                if ($line -and $line -match "\bimage:\s*\S+:(.+)$") {
                    $tags[$fileName] = $Matches[1].Trim()
                }
            }

            if ($tags.Count -ge 2) {
                $uniqueTags = $tags.Values | Sort-Object -Unique
                $report = ($tags.GetEnumerator() | ForEach-Object { "  $($_.Key) -> $($_.Value)" }) -join "`n"
                $uniqueTags.Count | Should -Be 1 `
                    -Because (
                        "$image must use the same pinned tag in all compose files to avoid " +
                        "version drift between deployment modes. Current tags:`n$report"
                    )
            }
        }
    }
}

# =============================================================================
# Phase 7  -  Integration: docker compose config validates all three files
# =============================================================================

Describe 'docker compose config  -  all three compose files parse without errors' {
    # Runs `docker compose config --quiet` to validate YAML syntax and
    # environment-variable interpolation (equivalent to test.ps1 Phase 2).
    # Tests are skipped automatically when Docker is not available.

    BeforeAll {
        $script:DockerAvailable = $false
        try {
            $null = docker compose version 2>&1
            $script:DockerAvailable = ($LASTEXITCODE -eq 0)
        } catch {
            $script:DockerAvailable = $false
        }

        # Supply the env vars that compose files require for interpolation
        $env:PUID         = '1000'
        $env:PGID         = '1000'
        $env:TZ           = 'UTC'
        $env:PLEX_CLAIM   = 'claim-test'
        $env:DOCKER_CONFIG = Join-Path ([System.IO.Path]::GetTempPath()) 'simplarr-pin-test-config'
        $env:DOCKER_MEDIA  = Join-Path ([System.IO.Path]::GetTempPath()) 'simplarr-pin-test-media'
    }

    AfterAll {
        foreach ($var in @('PUID', 'PGID', 'TZ', 'PLEX_CLAIM', 'DOCKER_CONFIG', 'DOCKER_MEDIA')) {
            Remove-Item "Env:$var" -ErrorAction SilentlyContinue
        }
    }

    It 'docker-compose-unified.yml should parse cleanly under docker compose config --quiet' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'Docker with Compose v2 is not available'
            return
        }
        Push-Location $script:RepoRoot
        try {
            $output     = docker compose -f $script:ComposePaths['docker-compose-unified.yml'] config --quiet 2>&1
            $exitCode   = $LASTEXITCODE
            $outputText = $output -join "`n"
            $exitCode | Should -Be 0 `
                -Because "docker-compose-unified.yml must parse without errors.`nOutput: $outputText"
        } finally {
            Pop-Location
        }
    }

    It 'docker-compose-nas.yml should parse cleanly under docker compose config --quiet' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'Docker with Compose v2 is not available'
            return
        }
        Push-Location $script:RepoRoot
        try {
            $output     = docker compose -f $script:ComposePaths['docker-compose-nas.yml'] config --quiet 2>&1
            $exitCode   = $LASTEXITCODE
            $outputText = $output -join "`n"
            $exitCode | Should -Be 0 `
                -Because "docker-compose-nas.yml must parse without errors.`nOutput: $outputText"
        } finally {
            Pop-Location
        }
    }

    It 'docker-compose-pi.yml should parse cleanly under docker compose config --quiet' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'Docker with Compose v2 is not available'
            return
        }
        Push-Location $script:RepoRoot
        try {
            $output     = docker compose -f $script:ComposePaths['docker-compose-pi.yml'] config --quiet 2>&1
            $exitCode   = $LASTEXITCODE
            $outputText = $output -join "`n"
            $exitCode | Should -Be 0 `
                -Because "docker-compose-pi.yml must parse without errors.`nOutput: $outputText"
        } finally {
            Pop-Location
        }
    }

    It 'docker compose config output should contain no :latest image references (unified)' {
        if (-not $script:DockerAvailable) {
            Set-ItResult -Skipped -Because 'Docker with Compose v2 is not available'
            return
        }
        Push-Location $script:RepoRoot
        try {
            $output = docker compose -f $script:ComposePaths['docker-compose-unified.yml'] config 2>&1
            $latestRefs = ($output -split '\r?\n') | Where-Object { $_ -match 'image:.*:latest' }
            $report = $latestRefs -join "`n"
            $latestRefs | Should -BeNullOrEmpty `
                -Because (
                    "docker compose config output for unified compose must contain no :latest " +
                    "image references after variable interpolation. Found:`n$report"
                )
        } finally {
            Pop-Location
        }
    }
}

# =============================================================================
# Phase 8  -  Acceptance criteria aggregate (mirrors work-item definition of done)
# =============================================================================

Describe 'Acceptance criteria  -  all pinning requirements satisfied' {

    It 'zero :latest tags across all three compose files combined (active lines only)' {
        $allLatestLines = @()
        foreach ($fileName in $script:ComposeFileNames) {
            $content = $script:ComposeContent[$fileName]
            if ($null -eq $content) { continue }

            $latestLines = ($content -split '\r?\n') |
                Where-Object { $_ -notmatch '^\s*#' } |
                Where-Object { $_ -match '\bimage:\s*\S+:latest\b' } |
                ForEach-Object { "${fileName}: $_" }

            $allLatestLines += $latestLines
        }

        $report = $allLatestLines -join "`n"
        $allLatestLines | Should -BeNullOrEmpty `
            -Because (
                "All active image: entries across all three compose files must use pinned version tags. " +
                "Found $($allLatestLines.Count) :latest reference(s):`n$report"
            )
    }

    It 'homepage/Dockerfile FROM line references a versioned nginx-alpine tag' {
        if (-not (Test-Path $script:HomepageDockerfile)) {
            Set-ItResult -Skipped -Because 'homepage/Dockerfile does not exist'
            return
        }
        $fromLines = ($script:DockerfileContent -split '\r?\n') |
            Where-Object { $_ -match '^\s*FROM\s+nginx:' }

        $fromLines | Should -Not -BeNullOrEmpty `
            -Because 'homepage/Dockerfile must have a FROM nginx: line'

        foreach ($line in $fromLines) {
            $line | Should -Not -Match 'FROM\s+nginx:latest' `
                -Because "homepage/Dockerfile must not use :latest: $line"
            $line | Should -Not -Match 'FROM\s+nginx:alpine\s*$' `
                -Because "homepage/Dockerfile must not use bare nginx:alpine (no version): $line"
            $line | Should -Match 'FROM\s+nginx:\d+\.\d+.*-alpine' `
                -Because "homepage/Dockerfile must pin a specific version like nginx:1.27-alpine: $line"
        }
    }

    It 'VERSIONS.md exists at the repository root' {
        $script:VersionsMd | Should -Exist `
            -Because 'VERSIONS.md must be created as part of this work item'
    }

    It 'VERSIONS.md documents all nine required services' {
        if ($null -eq $script:VersionsMdContent) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        $requiredShortNames = @('plex', 'radarr', 'sonarr', 'prowlarr', 'qbittorrent', 'tautulli', 'overseerr', 'nginx', 'gluetun')
        $missing = $requiredShortNames | Where-Object { $script:VersionsMdContent -notmatch $_ }
        $missing | Should -BeNullOrEmpty `
            -Because "VERSIONS.md must document all services. Missing: $($missing -join ', ')"
    }

    It 'VERSIONS.md contains version tags, dates, and URLs' {
        if ($null -eq $script:VersionsMdContent) {
            Set-ItResult -Skipped -Because 'VERSIONS.md does not exist yet'
            return
        }
        $script:VersionsMdContent | Should -Match '\d+\.\d+\.\d+' `
            -Because 'VERSIONS.md must include numeric version numbers'
        $script:VersionsMdContent | Should -Match '20\d{2}-\d{2}-\d{2}' `
            -Because 'VERSIONS.md must include release dates (YYYY-MM-DD)'
        $script:VersionsMdContent | Should -Match 'https://' `
            -Because 'VERSIONS.md must include upstream changelog/release URLs'
    }
}
