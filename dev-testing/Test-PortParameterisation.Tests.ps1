#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Port Parameterisation Tests (Pester)
# =============================================================================
# TDD tests for work item:
#   "PS: Remove inline port literals from configure.ps1 and make retry configurable"
#
# Acceptance criteria verified:
#   1. configure.ps1 declares $RadarrPort and $SonarrPort script parameters that
#      default from $env:RADARR_PORT / $env:SONARR_PORT
#   2. No port literal 7878 or 8989 appears outside the parameter default block
#      (covers Add-RadarrToOverseerr line ~529, Add-SonarrToOverseerr line ~578,
#       Add-RadarrToProwlarr line ~262, Add-SonarrToProwlarr line ~302)
#   3. API call payloads in Add-RadarrToOverseerr and Add-SonarrToOverseerr use
#      the $RadarrPort / $SonarrPort variables — not hardcoded integers
#   4. Wait-ForService MaxAttempts and SleepSeconds default from
#      $env:WAIT_MAX_ATTEMPTS / $env:WAIT_RETRY_SECS
#
# These tests FAIL on the current codebase (no $RadarrPort/$SonarrPort params,
# literal 7878/8989 outside param block, hardcoded Start-Sleep -Seconds 2) and
# PASS once the full implementation is in place.
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-PortParameterisation.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent $PSScriptRoot
    $script:ConfigurePs1 = Join-Path $script:RepoRoot 'configure.ps1'

    # -------------------------------------------------------------------------
    # Parse the script once using the PowerShell AST — gives precise extents
    # -------------------------------------------------------------------------
    $parseErrors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ConfigurePs1, [ref]$null, [ref]$parseErrors
    )
    $script:ParseErrors = $parseErrors

    # Raw source text (used for regex-based pattern checks)
    $script:Source = Get-Content -Raw $script:ConfigurePs1

    # Script-level param block (AST ScriptBlockAst.ParamBlock)
    $script:ParamBlock = $script:Ast.ParamBlock

    # Text of everything after the closing ")" of the script param block.
    # Any port literal that appears here violates the acceptance criterion.
    if ($script:ParamBlock) {
        $script:BodyAfterParam = $script:Source.Substring($script:ParamBlock.Extent.EndOffset)
    } else {
        # No param block found — the whole source is "after param"
        $script:BodyAfterParam = $script:Source
    }

    # -------------------------------------------------------------------------
    # Collect all function definition AST nodes
    # -------------------------------------------------------------------------
    $script:FunctionDefs = $script:Ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        },
        $true
    )

    function script:Get-FunctionSource ([string]$FunctionName) {
        $fn = $script:FunctionDefs |
              Where-Object { $_.Name -eq $FunctionName } |
              Select-Object -First 1
        if ($fn) { return $fn.Extent.Text }
        return ''
    }

    $script:WaitFnSrc      = Get-FunctionSource 'Wait-ForService'
    $script:AddRadarrOvSrc = Get-FunctionSource 'Add-RadarrToOverseerr'
    $script:AddSonarrOvSrc = Get-FunctionSource 'Add-SonarrToOverseerr'
    $script:AddRadarrPrSrc = Get-FunctionSource 'Add-RadarrToProwlarr'
    $script:AddSonarrPrSrc = Get-FunctionSource 'Add-SonarrToProwlarr'
}

# =============================================================================
# 1. New script parameters — $RadarrPort and $SonarrPort declarations
# =============================================================================

Describe 'configure.ps1 — $RadarrPort and $SonarrPort parameter declarations' {

    It 'should declare a $RadarrPort parameter in the script param block' {
        $script:ParamBlock | Should -Not -BeNullOrEmpty `
            -Because 'configure.ps1 must have a top-level param() block'

        $script:ParamBlock.Extent.Text | Should -Match '\$RadarrPort' `
            -Because '$RadarrPort must be a named script parameter so callers can override it'
    }

    It 'should declare a $SonarrPort parameter in the script param block' {
        $script:ParamBlock.Extent.Text | Should -Match '\$SonarrPort' `
            -Because '$SonarrPort must be a named script parameter so callers can override it'
    }

    It '$RadarrPort default should read from $env:RADARR_PORT' {
        $script:ParamBlock.Extent.Text | Should -Match '\$env:RADARR_PORT' `
            -Because 'When RADARR_PORT is set in the environment, $RadarrPort must honour it without requiring a caller-supplied argument'
    }

    It '$SonarrPort default should read from $env:SONARR_PORT' {
        $script:ParamBlock.Extent.Text | Should -Match '\$env:SONARR_PORT' `
            -Because 'When SONARR_PORT is set in the environment, $SonarrPort must honour it without requiring a caller-supplied argument'
    }
}

# =============================================================================
# 2. No port literals 7878 or 8989 outside the parameter default block
#    (main acceptance criterion from the work item)
# =============================================================================

Describe 'configure.ps1 — no port literals outside the parameter default block' {

    It 'should contain no literal 7878 outside the parameter default block' {
        $script:BodyAfterParam | Should -Not -Match '\b7878\b' `
            -Because (
                'After the refactor, the integer 7878 must only appear as a fallback ' +
                'inside the $RadarrPort parameter default. Any occurrence in function ' +
                'bodies (e.g. port = 7878 in Add-RadarrToOverseerr, or ' +
                '"http://...:7878" in Add-RadarrToProwlarr) must be replaced with ' +
                '$RadarrPort.'
            )
    }

    It 'should contain no literal 8989 outside the parameter default block' {
        $script:BodyAfterParam | Should -Not -Match '\b8989\b' `
            -Because (
                'After the refactor, the integer 8989 must only appear as a fallback ' +
                'inside the $SonarrPort parameter default. Any occurrence in function ' +
                'bodies (e.g. port = 8989 in Add-SonarrToOverseerr, or ' +
                '"http://...:8989" in Add-SonarrToProwlarr) must be replaced with ' +
                '$SonarrPort.'
            )
    }
}

# =============================================================================
# 3. Add-RadarrToOverseerr — port field uses $RadarrPort variable
# =============================================================================

Describe 'Add-RadarrToOverseerr — port field references $RadarrPort not a literal' {

    It 'Add-RadarrToOverseerr function should exist in configure.ps1' {
        $script:AddRadarrOvSrc | Should -Not -BeNullOrEmpty `
            -Because 'Add-RadarrToOverseerr must be defined in configure.ps1'
    }

    It 'should not contain the literal integer 7878 in the function body' {
        $script:AddRadarrOvSrc | Should -Not -Match '\b7878\b' `
            -Because 'The port field in the Overseerr radarr config must use $RadarrPort, not a hardcoded 7878'
    }

    It 'should reference $RadarrPort in the port assignment' {
        $script:AddRadarrOvSrc | Should -Match '\bport\s*=\s*\$RadarrPort\b' `
            -Because 'The port field must be set to $RadarrPort so that non-default ports are correctly forwarded to Overseerr'
    }
}

Describe 'Add-RadarrToOverseerr — behavioral: custom RadarrPort propagates to Overseerr POST body' {

    BeforeAll {
        # Provide stub helpers that the production function calls (Write-Info etc.)
        function Write-Info         { param([string]$Message) }
        function Write-Success      { param([string]$Message) }
        function Write-WarningMessage { param([string]$Message) }
        function Write-ErrorMessage { param([string]$Message) }

        # Load the production function definition into this test scope
        . ([ScriptBlock]::Create($script:AddRadarrOvSrc))

        # Set the script-scope variables that Add-RadarrToOverseerr reads
        $script:RadarrUrl    = 'http://radarr-test.local:9999'
        $script:OverseerrUrl = 'http://overseerr-test.local:5055'
        $script:RadarrHost   = 'radarr-test-host'
    }

    Context 'when RadarrPort is set to 9999' {

        BeforeEach {
            $script:RadarrPort              = 9999
            $script:CapturedOverseerrBody   = $null

            Mock Invoke-RestMethod {
                if ($Uri -match '/qualityprofile') { return @( @{ id = 1 } ) }
                if ($Uri -match '/rootfolder')     { return @( @{ path = '/movies' } ) }
                if ($Uri -match '/settings/radarr') {
                    $script:CapturedOverseerrBody = $Body
                    return $null
                }
                return $null
            }
        }

        It 'should POST port=9999 to the Overseerr radarr settings endpoint' {
            Add-RadarrToOverseerr -RadarrApiKey 'fake-radarr-key' -OverseerrApiKey 'fake-overseerr-key'

            $script:CapturedOverseerrBody | Should -Not -BeNullOrEmpty `
                -Because 'Add-RadarrToOverseerr must POST a config body to the Overseerr radarr settings endpoint'

            $payload = $script:CapturedOverseerrBody | ConvertFrom-Json
            $payload.port | Should -Be 9999 `
                -Because 'When $RadarrPort is 9999, the "port" field sent to Overseerr must be 9999, not the hardcoded literal 7878'
        }
    }

    Context 'when RadarrPort is set to 7878 (the default)' {

        BeforeEach {
            $script:RadarrPort            = 7878
            $script:CapturedOverseerrBody = $null

            Mock Invoke-RestMethod {
                if ($Uri -match '/qualityprofile') { return @( @{ id = 1 } ) }
                if ($Uri -match '/rootfolder')     { return @( @{ path = '/movies' } ) }
                if ($Uri -match '/settings/radarr') {
                    $script:CapturedOverseerrBody = $Body
                    return $null
                }
                return $null
            }
        }

        It 'should POST port=7878 when RadarrPort is the default' {
            Add-RadarrToOverseerr -RadarrApiKey 'fake-radarr-key' -OverseerrApiKey 'fake-overseerr-key'

            $payload = $script:CapturedOverseerrBody | ConvertFrom-Json
            $payload.port | Should -Be 7878 `
                -Because 'The default port for Radarr is 7878 and must be preserved when no override is given'
        }
    }
}

# =============================================================================
# 4. Add-SonarrToOverseerr — port field uses $SonarrPort variable
# =============================================================================

Describe 'Add-SonarrToOverseerr — port field references $SonarrPort not a literal' {

    It 'Add-SonarrToOverseerr function should exist in configure.ps1' {
        $script:AddSonarrOvSrc | Should -Not -BeNullOrEmpty `
            -Because 'Add-SonarrToOverseerr must be defined in configure.ps1'
    }

    It 'should not contain the literal integer 8989 in the function body' {
        $script:AddSonarrOvSrc | Should -Not -Match '\b8989\b' `
            -Because 'The port field in the Overseerr sonarr config must use $SonarrPort, not a hardcoded 8989'
    }

    It 'should reference $SonarrPort in the port assignment' {
        $script:AddSonarrOvSrc | Should -Match '\bport\s*=\s*\$SonarrPort\b' `
            -Because 'The port field must be set to $SonarrPort so that non-default ports are correctly forwarded to Overseerr'
    }
}

Describe 'Add-SonarrToOverseerr — behavioral: custom SonarrPort propagates to Overseerr POST body' {

    BeforeAll {
        function Write-Info         { param([string]$Message) }
        function Write-Success      { param([string]$Message) }
        function Write-WarningMessage { param([string]$Message) }
        function Write-ErrorMessage { param([string]$Message) }

        . ([ScriptBlock]::Create($script:AddSonarrOvSrc))

        $script:SonarrUrl    = 'http://sonarr-test.local:9998'
        $script:OverseerrUrl = 'http://overseerr-test.local:5055'
        $script:SonarrHost   = 'sonarr-test-host'
    }

    Context 'when SonarrPort is set to 9998' {

        BeforeEach {
            $script:SonarrPort            = 9998
            $script:CapturedOverseerrBody = $null

            Mock Invoke-RestMethod {
                if ($Uri -match '/qualityprofile') { return @( @{ id = 1 } ) }
                if ($Uri -match '/rootfolder')     { return @( @{ path = '/tv' } ) }
                if ($Uri -match '/settings/sonarr') {
                    $script:CapturedOverseerrBody = $Body
                    return $null
                }
                return $null
            }
        }

        It 'should POST port=9998 to the Overseerr sonarr settings endpoint' {
            Add-SonarrToOverseerr -SonarrApiKey 'fake-sonarr-key' -OverseerrApiKey 'fake-overseerr-key'

            $script:CapturedOverseerrBody | Should -Not -BeNullOrEmpty `
                -Because 'Add-SonarrToOverseerr must POST a config body to the Overseerr sonarr settings endpoint'

            $payload = $script:CapturedOverseerrBody | ConvertFrom-Json
            $payload.port | Should -Be 9998 `
                -Because 'When $SonarrPort is 9998, the "port" field sent to Overseerr must be 9998, not the hardcoded literal 8989'
        }
    }

    Context 'when SonarrPort is set to 8989 (the default)' {

        BeforeEach {
            $script:SonarrPort            = 8989
            $script:CapturedOverseerrBody = $null

            Mock Invoke-RestMethod {
                if ($Uri -match '/qualityprofile') { return @( @{ id = 1 } ) }
                if ($Uri -match '/rootfolder')     { return @( @{ path = '/tv' } ) }
                if ($Uri -match '/settings/sonarr') {
                    $script:CapturedOverseerrBody = $Body
                    return $null
                }
                return $null
            }
        }

        It 'should POST port=8989 when SonarrPort is the default' {
            Add-SonarrToOverseerr -SonarrApiKey 'fake-sonarr-key' -OverseerrApiKey 'fake-overseerr-key'

            $payload = $script:CapturedOverseerrBody | ConvertFrom-Json
            $payload.port | Should -Be 8989 `
                -Because 'The default port for Sonarr is 8989 and must be preserved when no override is given'
        }
    }
}

# =============================================================================
# 5. Add-RadarrToProwlarr — baseUrl field uses $RadarrPort not a literal
# =============================================================================

Describe 'Add-RadarrToProwlarr — baseUrl uses $RadarrPort not a literal' {

    It 'Add-RadarrToProwlarr function should exist in configure.ps1' {
        $script:AddRadarrPrSrc | Should -Not -BeNullOrEmpty `
            -Because 'Add-RadarrToProwlarr must be defined in configure.ps1'
    }

    It 'should not contain the literal 7878 in the function body' {
        $script:AddRadarrPrSrc | Should -Not -Match '\b7878\b' `
            -Because 'The Radarr baseUrl sent to Prowlarr must use $RadarrPort so non-default ports work'
    }

    It 'should reference $RadarrPort when constructing the Radarr baseUrl field' {
        $script:AddRadarrPrSrc | Should -Match '\$RadarrPort' `
            -Because 'The Radarr baseUrl field must interpolate $RadarrPort instead of a hardcoded 7878'
    }
}

# =============================================================================
# 6. Add-SonarrToProwlarr — baseUrl field uses $SonarrPort not a literal
# =============================================================================

Describe 'Add-SonarrToProwlarr — baseUrl uses $SonarrPort not a literal' {

    It 'Add-SonarrToProwlarr function should exist in configure.ps1' {
        $script:AddSonarrPrSrc | Should -Not -BeNullOrEmpty `
            -Because 'Add-SonarrToProwlarr must be defined in configure.ps1'
    }

    It 'should not contain the literal 8989 in the function body' {
        $script:AddSonarrPrSrc | Should -Not -Match '\b8989\b' `
            -Because 'The Sonarr baseUrl sent to Prowlarr must use $SonarrPort so non-default ports work'
    }

    It 'should reference $SonarrPort when constructing the Sonarr baseUrl field' {
        $script:AddSonarrPrSrc | Should -Match '\$SonarrPort' `
            -Because 'The Sonarr baseUrl field must interpolate $SonarrPort instead of a hardcoded 8989'
    }
}

# =============================================================================
# 7. Wait-ForService — MaxAttempts and SleepSeconds are environment-configurable
# =============================================================================

Describe 'Wait-ForService — retry parameters configurable from environment variables' {

    It 'Wait-ForService function should exist in configure.ps1' {
        $script:WaitFnSrc | Should -Not -BeNullOrEmpty `
            -Because 'Wait-ForService must be defined in configure.ps1'
    }

    It 'should declare a $SleepSeconds parameter' {
        $script:WaitFnSrc | Should -Match '\$SleepSeconds' `
            -Because 'SleepSeconds must be an explicit parameter so callers can override the retry interval'
    }

    It '$MaxAttempts default should read from $env:WAIT_MAX_ATTEMPTS' {
        $script:WaitFnSrc | Should -Match '\$env:WAIT_MAX_ATTEMPTS' `
            -Because 'Setting WAIT_MAX_ATTEMPTS in the environment must override the MaxAttempts default without requiring a script argument'
    }

    It '$SleepSeconds default should read from $env:WAIT_RETRY_SECS' {
        $script:WaitFnSrc | Should -Match '\$env:WAIT_RETRY_SECS' `
            -Because 'Setting WAIT_RETRY_SECS in the environment must override the SleepSeconds default without requiring a script argument'
    }

    It 'Start-Sleep call should use $SleepSeconds variable not a hardcoded integer' {
        $script:WaitFnSrc | Should -Match 'Start-Sleep\s+-Seconds\s+\$SleepSeconds' `
            -Because 'The sleep duration must come from $SleepSeconds, not a hardcoded literal (currently 2)'
    }

    It 'Start-Sleep call should NOT use the hardcoded literal 2' {
        $script:WaitFnSrc | Should -Not -Match 'Start-Sleep\s+-Seconds\s+2\b' `
            -Because 'Hardcoded "Start-Sleep -Seconds 2" must be replaced with $SleepSeconds to make the interval configurable'
    }
}

# =============================================================================
# 8. PSScriptAnalyzer — no new warnings introduced by the refactor
# =============================================================================

Describe 'configure.ps1 — PSScriptAnalyzer compliance maintained after refactor' {

    BeforeAll {
        if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
            Write-Warning 'PSScriptAnalyzer not installed — skipping static analysis check'
            $script:AnalyzerResults = $null
        } else {
            Import-Module PSScriptAnalyzer -ErrorAction Stop
            $script:AnalyzerResults = Invoke-ScriptAnalyzer `
                -Path $script:ConfigurePs1 `
                -Severity @('Warning', 'Error') `
                -ErrorAction Stop
        }
    }

    It 'should produce no new PSScriptAnalyzer warnings or errors after adding port parameters' {
        if ($null -eq $script:AnalyzerResults) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer module is not available in this environment'
            return
        }
        $report = $script:AnalyzerResults |
            ForEach-Object { "[$($_.Severity)] $($_.RuleName) at line $($_.Line): $($_.Message)" }
        $script:AnalyzerResults | Should -BeNullOrEmpty `
            -Because ("PSScriptAnalyzer must remain clean after the refactor. Found $($script:AnalyzerResults.Count) issue(s):`n" + ($report -join "`n"))
    }

    It 'should have no PSUseDeclaredVarsMoreThanAssignments violations for new parameters' {
        if ($null -eq $script:AnalyzerResults) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer module is not available in this environment'
            return
        }
        $violations = $script:AnalyzerResults |
            Where-Object { $_.RuleName -eq 'PSUseDeclaredVarsMoreThanAssignments' }
        $violations | Should -BeNullOrEmpty `
            -Because '$RadarrPort and $SonarrPort must be used in at least two places (URL defaults + API bodies) — declared but never used would indicate an incomplete refactor'
    }
}
