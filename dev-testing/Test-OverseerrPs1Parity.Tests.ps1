#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Overseerr OAuth Detection and PS1/SH Parity Tests (Pester)
# =============================================================================
# Validates that configure.ps1 detects Overseerr initialization from
# settings.json, wires all three Overseerr services when initialized, and
# prints a clear re-run instruction (no interactive prompt) when not
# initialized.
#
# TDD: Written BEFORE implementation — the following tests start RED:
#   - "should print a re-run instruction when Overseerr is not initialized"
#   - "should not use interactive Read-Host for Overseerr initialization"
#
# Acceptance criteria tested here:
#   (1) configure.ps1 detects Overseerr init state from settings.json
#   (2) Initialized path: calls all three Overseerr wiring functions
#   (3) Uninitialized path: actionable re-run instruction, no interactive wait
#   (4) PSScriptAnalyzer reports zero warnings
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-OverseerrPs1Parity.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
#   Install-Module PSScriptAnalyzer -Force
# =============================================================================

BeforeAll {
    # Locate repo root (one level up from dev-testing/)
    $script:RepoRoot      = Split-Path -Parent $PSScriptRoot
    $script:ConfigurePath = Join-Path $script:RepoRoot 'configure.ps1'
    $script:ShPath        = Join-Path $script:RepoRoot 'configure.sh'

    $script:ConfigureContent = Get-Content -Raw $script:ConfigurePath
    $script:ShContent        = Get-Content -Raw $script:ShPath
}

# =============================================================================
# 1. Overseerr initialization detection — must read settings.json
# =============================================================================

Describe 'configure.ps1 — Overseerr initialization detection via settings.json' {

    It 'should reference the Overseerr settings.json file to detect initialization' {
        $script:ConfigureContent | Should -Match 'overseerr.*settings\.json|settings\.json.*overseerr' `
            -Because 'configure.ps1 must read overseerr/settings.json to detect initialization state, not only the HTTP /status endpoint'
    }

    It 'should use ConvertFrom-Json to parse the Overseerr settings file' {
        $script:ConfigureContent | Should -Match 'ConvertFrom-Json' `
            -Because 'configure.ps1 must parse settings.json with ConvertFrom-Json to extract the Overseerr API key'
    }

    It 'should check the apiKey field from the parsed Overseerr settings' {
        $script:ConfigureContent | Should -Match '\.apiKey|\.main\.apiKey' `
            -Because 'configure.ps1 must inspect the apiKey field in settings.json to decide whether Overseerr is initialized'
    }

    It 'should derive the settings.json path from DOCKER_CONFIG environment variable' {
        $script:ConfigureContent | Should -Match 'DOCKER_CONFIG.*overseerr|overseerr.*DOCKER_CONFIG' `
            -Because 'configure.ps1 must build the settings.json path from $env:DOCKER_CONFIG, matching the configure.sh approach'
    }
}

# =============================================================================
# 2. Uninitialized path — actionable message + no interactive wait
#    >>> These two tests are RED (FAIL) until implementation is complete <<<
# =============================================================================

Describe 'configure.ps1 — Overseerr uninitialized path: actionable re-run message' {

    It 'should print a re-run instruction when Overseerr is not initialized' {
        # RED: configure.ps1 currently has no "re-run" instruction.
        # After implementation the uninitialized branch must tell users to sign
        # in at OverseerrUrl and then re-run the script.
        $script:ConfigureContent | Should -Match 're-run|run.*script.*again|run.*again' `
            -Because 'configure.ps1 must print a re-run instruction in the uninitialized path so the user knows what to do after completing Plex OAuth sign-in'
    }

    It 'should not use interactive Read-Host for Overseerr initialization detection' {
        # RED: configure.ps1 currently assigns $overseerrChoice = Read-Host "Continue".
        # After implementation the interactive wait must be removed; the script
        # should print the re-run message and continue (no blocking prompt).
        $script:ConfigureContent | Should -Not -Match '\$overseerrChoice' `
            -Because 'configure.ps1 must not interactively wait for the user to press Enter for Overseerr initialization — it must print a re-run instruction and exit the Overseerr section gracefully'
    }

    It 'should include the Overseerr URL in the uninitialized message' {
        $script:ConfigureContent | Should -Match 'OverseerrUrl' `
            -Because 'configure.ps1 must embed the Overseerr URL in the uninitialized message so the user knows exactly where to sign in'
    }

    It 'should mention Overseerr sign-in in the uninitialized message' {
        $script:ConfigureContent | Should -Match 'sign in|sign-in|Plex.*Overseerr|Overseerr.*Plex|not initialized' `
            -Because 'configure.ps1 must tell the user to sign in with their Plex account when Overseerr is not yet initialized'
    }
}

# =============================================================================
# 3. Initialized path — all three wiring functions must be called
# =============================================================================

Describe 'configure.ps1 — Overseerr initialized path wires all three services' {

    It 'should call Add-RadarrToOverseerr in the main execution flow' {
        $script:ConfigureContent | Should -Match 'Add-RadarrToOverseerr' `
            -Because 'configure.ps1 must call Add-RadarrToOverseerr to register Radarr in Overseerr when initialized'
    }

    It 'should call Add-SonarrToOverseerr in the main execution flow' {
        $script:ConfigureContent | Should -Match 'Add-SonarrToOverseerr' `
            -Because 'configure.ps1 must call Add-SonarrToOverseerr to register Sonarr in Overseerr when initialized'
    }

    It 'should call Enable-OverseerrWatchlistSync in the main execution flow' {
        $script:ConfigureContent | Should -Match 'Enable-OverseerrWatchlistSync' `
            -Because 'configure.ps1 must call Enable-OverseerrWatchlistSync to enable Plex watchlist auto-approval when initialized'
    }

    It 'should pass the Radarr API key to Add-RadarrToOverseerr' {
        $script:ConfigureContent | Should -Match 'Add-RadarrToOverseerr.*-RadarrApiKey|Add-RadarrToOverseerr.*RadarrApiKey' `
            -Because 'configure.ps1 must forward the Radarr API key to Add-RadarrToOverseerr'
    }

    It 'should pass the Sonarr API key to Add-SonarrToOverseerr' {
        $script:ConfigureContent | Should -Match 'Add-SonarrToOverseerr.*-SonarrApiKey|Add-SonarrToOverseerr.*SonarrApiKey' `
            -Because 'configure.ps1 must forward the Sonarr API key to Add-SonarrToOverseerr'
    }

    It 'should pass an Overseerr API key to all three wiring functions' {
        # All three calls should receive an OverseerrApiKey argument
        $hasRadarr  = $script:ConfigureContent -match 'Add-RadarrToOverseerr.*OverseerrApiKey'
        $hasSonarr  = $script:ConfigureContent -match 'Add-SonarrToOverseerr.*OverseerrApiKey'
        $hasSync    = $script:ConfigureContent -match 'Enable-OverseerrWatchlistSync.*OverseerrApiKey'
        ($hasRadarr -and $hasSonarr -and $hasSync) | Should -BeTrue `
            -Because 'All three Overseerr wiring calls must receive the OverseerrApiKey retrieved from settings.json'
    }
}

# =============================================================================
# 4. Wiring function definitions — functions must be defined in the script
# =============================================================================

Describe 'configure.ps1 — Overseerr wiring function definitions present' {

    It 'should define the Add-RadarrToOverseerr function' {
        $script:ConfigureContent | Should -Match 'function\s+Add-RadarrToOverseerr' `
            -Because 'configure.ps1 must define Add-RadarrToOverseerr'
    }

    It 'should define the Add-SonarrToOverseerr function' {
        $script:ConfigureContent | Should -Match 'function\s+Add-SonarrToOverseerr' `
            -Because 'configure.ps1 must define Add-SonarrToOverseerr'
    }

    It 'should define the Enable-OverseerrWatchlistSync function' {
        $script:ConfigureContent | Should -Match 'function\s+Enable-OverseerrWatchlistSync' `
            -Because 'configure.ps1 must define Enable-OverseerrWatchlistSync'
    }

    It 'should define the Get-OverseerrApiKey function for settings.json reading' {
        $script:ConfigureContent | Should -Match 'function\s+Get-OverseerrApiKey' `
            -Because 'configure.ps1 must define Get-OverseerrApiKey to encapsulate settings.json parsing'
    }
}

# =============================================================================
# 5. PSScriptAnalyzer compliance — no new warnings introduced
# =============================================================================

Describe 'configure.ps1 — PSScriptAnalyzer compliance after Overseerr changes' {

    BeforeAll {
        if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
            Write-Warning 'PSScriptAnalyzer not found — installing...'
            Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module PSScriptAnalyzer -ErrorAction Stop

        $script:AnalyzerFindings = Invoke-ScriptAnalyzer `
            -Path $script:ConfigurePath `
            -Severity @('Warning', 'Error') `
            -ErrorAction Stop
    }

    It 'should produce no PSScriptAnalyzer warnings or errors after Overseerr changes' {
        $report = $script:AnalyzerFindings |
            ForEach-Object { "[$($_.Severity)] $($_.RuleName) at line $($_.Line): $($_.Message)" }
        $script:AnalyzerFindings | Should -BeNullOrEmpty `
            -Because ("configure.ps1 must have zero PSScriptAnalyzer findings. Found $($script:AnalyzerFindings.Count) issue(s):`n" + ($report -join "`n"))
    }

    It 'should have no PSUseDeclaredVarsMoreThanAssignments violations' {
        $violations = $script:AnalyzerFindings |
            Where-Object { $_.RuleName -eq 'PSUseDeclaredVarsMoreThanAssignments' }
        $violations | Should -BeNullOrEmpty `
            -Because 'Any variable declared for Overseerr init detection must be read, not just assigned'
    }

    It 'should have no PSAvoidOverwritingBuiltInCmdlets violations' {
        $violations = $script:AnalyzerFindings |
            Where-Object { $_.RuleName -eq 'PSAvoidOverwritingBuiltInCmdlets' }
        $violations | Should -BeNullOrEmpty `
            -Because 'configure.ps1 must not shadow built-in cmdlets such as Write-Warning or Write-Error'
    }
}

# =============================================================================
# 6. Parity with configure.sh — consistent behavior across both scripts
# =============================================================================

Describe 'configure.ps1 — parity with configure.sh Overseerr behavior' {

    It 'should reference overseerr/settings.json — same as configure.sh' {
        $script:ConfigureContent | Should -Match 'overseerr.*settings\.json|settings\.json.*overseerr' `
            -Because 'configure.ps1 must read settings.json for initialization, matching configure.sh'
        $script:ShContent | Should -Match 'overseerr.*settings\.json|settings\.json.*overseerr' `
            -Because 'configure.sh reads settings.json (parity reference)'
    }

    It 'should register Radarr in Overseerr via /api/v1/settings/radarr — same as configure.sh' {
        $script:ConfigureContent | Should -Match 'settings/radarr' `
            -Because 'configure.ps1 must POST to /api/v1/settings/radarr, matching configure.sh'
        $script:ShContent | Should -Match 'settings/radarr' `
            -Because 'configure.sh uses /api/v1/settings/radarr (parity reference)'
    }

    It 'should register Sonarr in Overseerr via /api/v1/settings/sonarr — same as configure.sh' {
        $script:ConfigureContent | Should -Match 'settings/sonarr' `
            -Because 'configure.ps1 must POST to /api/v1/settings/sonarr, matching configure.sh'
        $script:ShContent | Should -Match 'settings/sonarr' `
            -Because 'configure.sh uses /api/v1/settings/sonarr (parity reference)'
    }

    It 'should enable watchlist sync in Overseerr — matching configure.sh behavior' {
        $script:ConfigureContent | Should -Match 'autoApproveMovie|autoApproveSeries|watchlist' `
            -Because 'configure.ps1 must enable auto-approval / watchlist sync, matching configure.sh'
        $script:ShContent | Should -Match 'autoApproveMovie|autoApproveSeries|watchlist' `
            -Because 'configure.sh enables watchlist sync (parity reference)'
    }

    It 'should handle the uninitialized Overseerr state gracefully — like configure.sh' {
        $script:ConfigureContent | Should -Match 'not initialized|not yet initialized|not.*initializ' `
            -Because 'configure.ps1 must handle the uninitialized state, matching configure.sh which logs an error and skips'
        $script:ShContent | Should -Match 'not initialized|not yet initialized|not.*initializ' `
            -Because 'configure.sh handles the uninitialized state (parity reference)'
    }
}

# =============================================================================
# 7. Behavioral regression — existing service wiring still intact
# =============================================================================

Describe 'configure.ps1 — behavioral regression after Overseerr parity changes' {

    It 'should still add qBittorrent as download client to Radarr' {
        $script:ConfigureContent | Should -Match 'downloadclient' `
            -Because 'configure.ps1 must still wire qBittorrent as download client to Radarr and Sonarr'
    }

    It 'should still configure root folders for Radarr and Sonarr' {
        $script:ConfigureContent | Should -Match 'rootfolder' `
            -Because 'configure.ps1 must still add root folders to Radarr (/movies) and Sonarr (/tv)'
        $script:ConfigureContent | Should -Match '/movies' `
            -Because 'configure.ps1 must still set /movies as Radarr root folder'
        $script:ConfigureContent | Should -Match '/tv' `
            -Because 'configure.ps1 must still set /tv as Sonarr root folder'
    }

    It 'should still connect Prowlarr to Radarr and Sonarr via applications API' {
        $script:ConfigureContent | Should -Match 'applications' `
            -Because 'configure.ps1 must still call /api/v1/applications to register Radarr and Sonarr in Prowlarr'
    }

    It 'should still add public indexers to Prowlarr' {
        $script:ConfigureContent | Should -Match 'indexer' `
            -Because 'configure.ps1 must still add public indexers to Prowlarr'
    }

    It 'should still extract API keys from arr config XML files' {
        $script:ConfigureContent | Should -Match 'config\.xml' `
            -Because 'configure.ps1 must still read API keys from service config.xml files'
        $script:ConfigureContent | Should -Match '<ApiKey>' `
            -Because 'configure.ps1 must still parse the <ApiKey> element from arr config XML'
    }

    It 'should still wait for services to be ready before configuring' {
        $script:ConfigureContent | Should -Match 'Wait-ForService' `
            -Because 'configure.ps1 must still poll services until they respond before attempting configuration'
    }

    It 'should still trigger Prowlarr indexer sync after adding indexers' {
        $script:ConfigureContent | Should -Match 'ApplicationIndexerSync' `
            -Because 'configure.ps1 must still trigger the Prowlarr ApplicationIndexerSync command'
    }

    It 'should still parse qBittorrent temporary password from docker logs' {
        $script:ConfigureContent | Should -Match 'docker logs' `
            -Because 'configure.ps1 must still retrieve the qBittorrent temporary password from container logs'
        $script:ConfigureContent | Should -Match 'temporary password' `
            -Because 'configure.ps1 must still parse the "temporary password" pattern from qBittorrent logs'
    }
}

# =============================================================================
# 8. Syntax — script must remain parseable after changes
# =============================================================================

Describe 'configure.ps1 — valid PowerShell syntax after Overseerr changes' {

    It 'should parse as valid PowerShell without syntax errors' {
        $parseErrors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize($script:ConfigureContent, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty `
            -Because 'configure.ps1 must remain syntactically valid after the Overseerr parity changes'
    }
}
