#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# PSScriptAnalyzer Compliance Tests (Pester)
# =============================================================================
# These tests verify that all .ps1 scripts pass PSScriptAnalyzer with zero
# warnings or errors, and that no behavioral regressions were introduced
# during the cleanup.
#
# TDD: These tests are written BEFORE fixes exist and are expected to fail
# until Invoke-ScriptAnalyzer returns no results for all three scripts.
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-PSScriptAnalyzer.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module PSScriptAnalyzer -Force
#   Install-Module Pester -MinimumVersion 5.0 -Force
# =============================================================================

BeforeAll {
    # Locate repo root (one level up from dev-testing/)
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    # Ensure PSScriptAnalyzer is available  -  install if missing
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        Write-Warning "PSScriptAnalyzer not found - installing..."
        Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    # The three scripts under test
    $script:Scripts = @{
        'setup.ps1'     = Join-Path $script:RepoRoot 'setup.ps1'
        'configure.ps1' = Join-Path $script:RepoRoot 'configure.ps1'
        'preflight.ps1' = Join-Path $script:RepoRoot 'preflight.ps1'
    }

    # Cache analyzer results once per test run to keep tests fast
    $script:AnalyzerResults = @{}
    foreach ($name in $script:Scripts.Keys) {
        $path = $script:Scripts[$name]
        $script:AnalyzerResults[$name] = Invoke-ScriptAnalyzer `
            -Path $path `
            -Severity @('Warning', 'Error') `
            -ErrorAction Stop
    }
}

# =============================================================================
# 1. PSScriptAnalyzer  -  Zero Warnings / Errors
# =============================================================================

Describe 'PSScriptAnalyzer compliance  -  zero warnings and errors' {

    Context 'setup.ps1' {
        It 'should produce no PSScriptAnalyzer warnings or errors' {
            $findings = $script:AnalyzerResults['setup.ps1']
            $report   = $findings | ForEach-Object { "[$($_.Severity)] $($_.RuleName) at line $($_.Line): $($_.Message)" }
            $findings | Should -BeNullOrEmpty -Because ("PSScriptAnalyzer found $($findings.Count) issue(s):`n" + ($report -join "`n"))
        }

        It 'should have no PSAvoidOverwritingBuiltInCmdlets violations' {
            $violations = $script:AnalyzerResults['setup.ps1'] |
                Where-Object { $_.RuleName -eq 'PSAvoidOverwritingBuiltInCmdlets' }
            $violations | Should -BeNullOrEmpty `
                -Because 'setup.ps1 must not define functions whose names shadow built-in cmdlets (e.g. Write-Warning, Write-Error)'
        }

        It 'should have no PSUseApprovedVerbs violations' {
            $violations = $script:AnalyzerResults['setup.ps1'] |
                Where-Object { $_.RuleName -eq 'PSUseApprovedVerbs' }
            $violations | Should -BeNullOrEmpty `
                -Because 'All function names in setup.ps1 must use approved PowerShell verbs (e.g. Load- is not approved)'
        }

        It 'should have no PSAvoidAssignmentToAutomaticVariable violations' {
            $violations = $script:AnalyzerResults['setup.ps1'] |
                Where-Object { $_.RuleName -eq 'PSAvoidAssignmentToAutomaticVariable' }
            $violations | Should -BeNullOrEmpty `
                -Because 'setup.ps1 must not assign to automatic variables such as $input'
        }
    }

    Context 'configure.ps1' {
        It 'should produce no PSScriptAnalyzer warnings or errors' {
            $findings = $script:AnalyzerResults['configure.ps1']
            $report   = $findings | ForEach-Object { "[$($_.Severity)] $($_.RuleName) at line $($_.Line): $($_.Message)" }
            $findings | Should -BeNullOrEmpty -Because ("PSScriptAnalyzer found $($findings.Count) issue(s):`n" + ($report -join "`n"))
        }

        It 'should have no PSAvoidOverwritingBuiltInCmdlets violations' {
            $violations = $script:AnalyzerResults['configure.ps1'] |
                Where-Object { $_.RuleName -eq 'PSAvoidOverwritingBuiltInCmdlets' }
            $violations | Should -BeNullOrEmpty `
                -Because 'configure.ps1 must not define Write-Warning or Write-Error (shadow built-in cmdlets)'
        }

        It 'should have no PSUseDeclaredVarsMoreThanAssignments violations' {
            $violations = $script:AnalyzerResults['configure.ps1'] |
                Where-Object { $_.RuleName -eq 'PSUseDeclaredVarsMoreThanAssignments' }
            $violations | Should -BeNullOrEmpty `
                -Because 'configure.ps1 must not declare variables that are never used (e.g. $PlexHost, $OverseerrHost, $response)'
        }
    }

    Context 'preflight.ps1' {
        It 'should produce no PSScriptAnalyzer warnings or errors' {
            $findings = $script:AnalyzerResults['preflight.ps1']
            $report   = $findings | ForEach-Object { "[$($_.Severity)] $($_.RuleName) at line $($_.Line): $($_.Message)" }
            $findings | Should -BeNullOrEmpty -Because ("PSScriptAnalyzer found $($findings.Count) issue(s):`n" + ($report -join "`n"))
        }

        It 'should have no PSUseApprovedVerbs violations' {
            $violations = $script:AnalyzerResults['preflight.ps1'] |
                Where-Object { $_.RuleName -eq 'PSUseApprovedVerbs' }
            $violations | Should -BeNullOrEmpty `
                -Because 'preflight.ps1 must not use non-approved verbs (Print- is not approved; functions Pass/Fail/Warn/Info lack verb-noun format)'
        }

        It 'should have no PSUseDeclaredVarsMoreThanAssignments violations' {
            $violations = $script:AnalyzerResults['preflight.ps1'] |
                Where-Object { $_.RuleName -eq 'PSUseDeclaredVarsMoreThanAssignments' }
            $violations | Should -BeNullOrEmpty `
                -Because 'preflight.ps1 must not have unused variables (e.g. $dockerInfo assigned but never read)'
        }
    }
}

# =============================================================================
# 2. Suppression Attributes  -  must have justification
# =============================================================================

Describe 'SuppressMessageAttribute usage  -  justification required' {

    foreach ($name in @('setup.ps1', 'configure.ps1', 'preflight.ps1')) {
        Context $name {
            It "should not suppress any PSScriptAnalyzer rules without a justification comment in $name" {
                $path    = $script:Scripts[$name]
                $content = Get-Content -Raw $path

                # Find all SuppressMessageAttribute occurrences
                $suppressions = [regex]::Matches(
                    $content,
                    '\[Diagnostics\.CodeAnalysis\.SuppressMessageAttribute\s*\([^)]+\)\]'
                )

                foreach ($suppression in $suppressions) {
                    # Each suppression must include a Justification named argument
                    $suppression.Value | Should -Match 'Justification\s*=' `
                        -Because "Every [SuppressMessageAttribute] in $name must include a Justification= argument explaining why the rule is suppressed (found: $($suppression.Value))"
                }
            }
        }
    }
}

# =============================================================================
# 3. Syntax validation  -  scripts must parse without errors
#    (regression guard: fixes must not break PowerShell syntax)
# =============================================================================

Describe 'Script syntax  -  valid PowerShell after analyzer fixes' {

    foreach ($name in @('setup.ps1', 'configure.ps1', 'preflight.ps1')) {
        Context $name {
            It "should parse as valid PowerShell syntax in $name" {
                $path    = $script:Scripts[$name]
                $content = Get-Content -Raw $path
                $errors  = $null
                $null    = [System.Management.Automation.PSParser]::Tokenize($content, [ref]$errors)
                $errors  | Should -BeNullOrEmpty `
                    -Because "$name must remain syntactically valid after PSScriptAnalyzer fixes"
            }
        }
    }
}

# =============================================================================
# 4. Behavioral regression  -  setup.ps1
#    Validates that all key functionality is still present after rename/refactors.
# =============================================================================

Describe 'setup.ps1  -  behavioral regression after PSScriptAnalyzer fixes' {

    BeforeAll {
        $script:SetupContent = Get-Content -Raw $script:Scripts['setup.ps1']
    }

    It 'should still prompt for and write PUID to .env' {
        $script:SetupContent | Should -Match 'PUID' `
            -Because 'setup.ps1 must still handle the PUID environment variable'
    }

    It 'should still prompt for and write PGID to .env' {
        $script:SetupContent | Should -Match 'PGID' `
            -Because 'setup.ps1 must still handle the PGID environment variable'
    }

    It 'should still prompt for timezone (TZ)' {
        $script:SetupContent | Should -Match 'TZ=' `
            -Because 'setup.ps1 must still write TZ to the .env file'
    }

    It 'should still prompt for DOCKER_CONFIG path' {
        $script:SetupContent | Should -Match 'DOCKER_CONFIG' `
            -Because 'setup.ps1 must still configure the DOCKER_CONFIG path'
    }

    It 'should still prompt for DOCKER_MEDIA path' {
        $script:SetupContent | Should -Match 'DOCKER_MEDIA' `
            -Because 'setup.ps1 must still configure the DOCKER_MEDIA path'
    }

    It 'should still prompt for PLEX_CLAIM token' {
        $script:SetupContent | Should -Match 'PLEX_CLAIM' `
            -Because 'setup.ps1 must still accept the Plex claim token'
    }

    It 'should still support both unified and split deployment modes' {
        $script:SetupContent | Should -Match 'unified' `
            -Because 'setup.ps1 must still support the unified deployment mode'
        $script:SetupContent | Should -Match 'split' `
            -Because 'setup.ps1 must still support the split deployment mode'
    }

    It 'should still load existing .env values as defaults' {
        # The function that reads an existing .env (possibly renamed from Load-ExistingEnv)
        # must still exist  -  check for the behavioral marker: reading .env key=value pairs
        $script:SetupContent | Should -Match 'Get-Content.*FilePath|Get-Content.*EnvFile' `
            -Because 'setup.ps1 must still read an existing .env file to populate defaults'
    }

    It 'should still deploy the qBittorrent pre-configured template' {
        $script:SetupContent | Should -Match 'qBittorrent' `
            -Because 'setup.ps1 must still copy the qBittorrent template'
        $script:SetupContent | Should -Match 'templates' `
            -Because 'setup.ps1 must still reference the templates directory'
    }

    It 'should still back up an existing .env file before overwriting' {
        $script:SetupContent | Should -Match 'backup|\.backup\.' `
            -Because 'setup.ps1 must still create a timestamped backup of existing .env'
    }

    It 'should still write the .env file using Out-File' {
        $script:SetupContent | Should -Match 'Out-File' `
            -Because 'setup.ps1 must still persist the configuration to disk'
    }

    It 'should still accept user input via Read-Host' {
        $script:SetupContent | Should -Match 'Read-Host' `
            -Because 'setup.ps1 is an interactive script and must still prompt via Read-Host'
    }

    It 'should still validate directory paths and offer to create them' {
        $script:SetupContent | Should -Match 'New-Item.*Directory' `
            -Because 'setup.ps1 must still offer to create missing directories'
    }
}

# =============================================================================
# 5. Behavioral regression  -  configure.ps1
# =============================================================================

Describe 'configure.ps1  -  behavioral regression after PSScriptAnalyzer fixes' {

    BeforeAll {
        $script:ConfigureContent = Get-Content -Raw $script:Scripts['configure.ps1']
    }

    It 'should still add qBittorrent as download client to Radarr' {
        $script:ConfigureContent | Should -Match 'downloadclient' `
            -Because 'configure.ps1 must still wire qBittorrent as download client'
        $script:ConfigureContent | Should -Match 'RadarrUrl|radarr' `
            -Because 'configure.ps1 must still configure Radarr'
    }

    It 'should still add qBittorrent as download client to Sonarr' {
        $script:ConfigureContent | Should -Match 'SonarrUrl|sonarr' `
            -Because 'configure.ps1 must still configure Sonarr'
    }

    It 'should still connect Prowlarr to Radarr for indexer sync' {
        $script:ConfigureContent | Should -Match 'ProwlarrUrl|prowlarr' `
            -Because 'configure.ps1 must still register Prowlarr connections'
        $script:ConfigureContent | Should -Match 'applications' `
            -Because 'configure.ps1 must still call the Prowlarr /applications API endpoint'
    }

    It 'should still add public indexers to Prowlarr' {
        $script:ConfigureContent | Should -Match 'indexer' `
            -Because 'configure.ps1 must still add public indexers to Prowlarr'
    }

    It 'should still configure root folders for Radarr and Sonarr' {
        $script:ConfigureContent | Should -Match 'rootfolder' `
            -Because 'configure.ps1 must still set root folders in Radarr/Sonarr'
        $script:ConfigureContent | Should -Match '/movies' `
            -Because 'configure.ps1 must still set the /movies root folder'
        $script:ConfigureContent | Should -Match '/tv' `
            -Because 'configure.ps1 must still set the /tv root folder'
    }

    It 'should still extract API keys from *arr config XML files' {
        $script:ConfigureContent | Should -Match 'ApiKey' `
            -Because 'configure.ps1 must still parse API keys from config.xml files'
        $script:ConfigureContent | Should -Match 'config\.xml' `
            -Because 'configure.ps1 must still read from service config.xml'
    }

    It 'should still retrieve qBittorrent temporary password from docker logs' {
        $script:ConfigureContent | Should -Match 'docker logs' `
            -Because 'configure.ps1 must still retrieve the qBittorrent password from container logs'
        $script:ConfigureContent | Should -Match 'temporary password' `
            -Because 'configure.ps1 must still parse the temporary password pattern'
    }

    It 'should still trigger Prowlarr indexer sync after adding indexers' {
        $script:ConfigureContent | Should -Match 'ApplicationIndexerSync' `
            -Because 'configure.ps1 must still trigger the Prowlarr sync command'
    }

    It 'should still wait for services to become ready before configuring' {
        $script:ConfigureContent | Should -Match 'Wait-ForService|Invoke-WebRequest' `
            -Because 'configure.ps1 must still poll services until they respond'
    }

    It 'should still configure Overseerr with Radarr and Sonarr' {
        $script:ConfigureContent | Should -Match 'Overseerr' `
            -Because 'configure.ps1 must still configure Overseerr'
        $script:ConfigureContent | Should -Match 'settings/radarr' `
            -Because 'configure.ps1 must still register Radarr in Overseerr'
        $script:ConfigureContent | Should -Match 'settings/sonarr' `
            -Because 'configure.ps1 must still register Sonarr in Overseerr'
    }
}

# =============================================================================
# 6. Behavioral regression  -  preflight.ps1
# =============================================================================

Describe 'preflight.ps1  -  behavioral regression after PSScriptAnalyzer fixes' {

    BeforeAll {
        $script:PreflightContent = Get-Content -Raw $script:Scripts['preflight.ps1']
    }

    It 'should still check Docker installation' {
        $script:PreflightContent | Should -Match 'docker' `
            -Because 'preflight.ps1 must still verify Docker is installed'
        $script:PreflightContent | Should -Match 'Get-Command docker' `
            -Because 'preflight.ps1 must still use Get-Command to locate docker'
    }

    It 'should still check Docker daemon is running' {
        $script:PreflightContent | Should -Match 'docker info' `
            -Because 'preflight.ps1 must still run docker info to verify daemon is running'
    }

    It 'should still validate the .env file exists and contains required variables' {
        $script:PreflightContent | Should -Match 'DOCKER_CONFIG|DOCKER_MEDIA|PUID|PGID|TZ' `
            -Because 'preflight.ps1 must still validate required env variables'
        $script:PreflightContent | Should -Match 'RequiredVars' `
            -Because 'preflight.ps1 must still iterate the required variables list'
    }

    It 'should still check port availability for all services' {
        $script:PreflightContent | Should -Match '32400' `
            -Because 'preflight.ps1 must still check the Plex port (32400)'
        $script:PreflightContent | Should -Match '7878' `
            -Because 'preflight.ps1 must still check the Radarr port (7878)'
        $script:PreflightContent | Should -Match '8989' `
            -Because 'preflight.ps1 must still check the Sonarr port (8989)'
        $script:PreflightContent | Should -Match '9696' `
            -Because 'preflight.ps1 must still check the Prowlarr port (9696)'
        $script:PreflightContent | Should -Match '8080' `
            -Because 'preflight.ps1 must still check the qBittorrent port (8080)'
    }

    It 'should still test network connectivity to Docker Hub' {
        $script:PreflightContent | Should -Match 'Docker Hub|docker pull hello-world' `
            -Because 'preflight.ps1 must still verify Docker Hub connectivity'
    }

    It 'should still validate DOCKER_CONFIG directory is writable' {
        $script:PreflightContent | Should -Match 'writable|WriteAllText' `
            -Because 'preflight.ps1 must still test that DOCKER_CONFIG is writable'
    }

    It 'should still detect placeholder values in .env variables' {
        $script:PreflightContent | Should -Match 'PlaceholderValues|placeholder' `
            -Because 'preflight.ps1 must still reject placeholder values in configuration'
    }

    It 'should still exit with code 0 on all-pass, 1 on failures, 2 on warnings-only' {
        $script:PreflightContent | Should -Match 'exit 0' `
            -Because 'preflight.ps1 must still exit 0 when all checks pass'
        $script:PreflightContent | Should -Match 'exit 1' `
            -Because 'preflight.ps1 must still exit 1 when critical failures are found'
        $script:PreflightContent | Should -Match 'exit 2' `
            -Because 'preflight.ps1 must still exit 2 when only warnings are found'
    }

    It 'should still track pass/fail/warn counters' {
        $script:PreflightContent | Should -Match 'PassCount|FailCount|WarnCount' `
            -Because 'preflight.ps1 must still maintain test result counters'
    }

    It 'should still check required media subdirectories (movies, tv, downloads)' {
        $script:PreflightContent | Should -Match 'RequiredSubdirs' `
            -Because 'preflight.ps1 must still validate required media subdirectories'
        $script:PreflightContent | Should -Match 'movies' `
            -Because 'preflight.ps1 must still check for movies/ subdirectory'
        $script:PreflightContent | Should -Match 'downloads' `
            -Because 'preflight.ps1 must still check for downloads/ subdirectory'
    }
}

# =============================================================================
# 7. Aggregate  -  all three scripts pass together (mirrors acceptance criteria)
# =============================================================================

Describe 'Acceptance criteria  -  Invoke-ScriptAnalyzer across all scripts returns no results' {

    It 'zero PSScriptAnalyzer warnings or errors across setup.ps1, configure.ps1, and preflight.ps1 combined' {
        $allFindings = @()
        foreach ($name in $script:Scripts.Keys) {
            $allFindings += $script:AnalyzerResults[$name] |
                ForEach-Object { [pscustomobject]@{ Script = $name; Rule = $_.RuleName; Line = $_.Line; Severity = $_.Severity; Message = $_.Message } }
        }

        $report = $allFindings | ForEach-Object {
            "  [$($_.Severity)] $($_.Script) line $($_.Line)  -  $($_.Rule): $($_.Message)"
        }

        $allFindings | Should -BeNullOrEmpty `
            -Because ("Invoke-ScriptAnalyzer must return 0 results across all three scripts. Found $($allFindings.Count) issue(s):`n" + ($report -join "`n"))
    }
}
