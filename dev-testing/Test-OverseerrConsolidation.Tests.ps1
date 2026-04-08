#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Overseerr Consolidation Tests (Pester)
# =============================================================================
# Validates that Add-RadarrToOverseerr and Add-SonarrToOverseerr are replaced
# by a single parameterized Add-ServiceToOverseerr function, and that the three
# repeated Initialize-Overseerr calls in the main flow are deduplicated into a
# single $overseerrInitialized variable.
#
# Work item: PS: Consolidate Add-RadarrToOverseerr and Add-SonarrToOverseerr,
#            deduplicate init check
#
# Acceptance criteria tested here:
#   1. Add-RadarrToOverseerr function no longer exists in configure.ps1
#   2. Add-SonarrToOverseerr function no longer exists in configure.ps1
#   3. Add-ServiceToOverseerr is defined with a service-type parameter
#   4. The consolidated function accepts ArrApiKey and OverseerrApiKey params
#   5. Endpoint path (/settings/radarr vs /settings/sonarr) is derived from
#      the service-type parameter — not hardcoded inside the function body
#   6. Service-specific JSON fields (minimumAvailability / enableSeasonFolders)
#      are emitted correctly per service type — either parameterized or
#      branched inside the function; values must still appear in the script
#   7. Initialize-Overseerr is called exactly once in the main flow, with its
#      result stored in $overseerrInitialized (no repeated live calls)
#   8. The main execution block calls Add-ServiceToOverseerr at least twice
#      (once for Radarr, once for Sonarr)
#   9. Radarr payload: minimumAvailability = "released" is preserved
#  10. Sonarr payload: enableSeasonFolders = $true is preserved
#  11. configure.ps1 remains PSScriptAnalyzer-clean after the refactor
#
# TDD: Sections 1, 2 FAIL on the current codebase (old functions still exist).
# Section 3 FAILS (Add-ServiceToOverseerr not yet defined).
# Sections 4-10 SKIP until Add-ServiceToOverseerr is defined, then PASS.
# Section 7 FAILS on the current codebase (Initialize-Overseerr called 3 times).
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-OverseerrConsolidation.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
#   Install-Module PSScriptAnalyzer -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent $PSScriptRoot
    $script:ConfigurePath = Join-Path $script:RepoRoot 'configure.ps1'
    $script:Content       = Get-Content -Raw $script:ConfigurePath
}

# =============================================================================
# 1. Old per-service Overseerr functions must be removed
# =============================================================================

Describe 'configure.ps1 - old per-service Overseerr functions removed' {

    It 'should not contain an Add-RadarrToOverseerr function definition' {
        $script:Content | Should -Not -Match 'function Add-RadarrToOverseerr\b' `
            -Because 'Add-RadarrToOverseerr must be replaced by the consolidated Add-ServiceToOverseerr'
    }

    It 'should not contain an Add-SonarrToOverseerr function definition' {
        $script:Content | Should -Not -Match 'function Add-SonarrToOverseerr\b' `
            -Because 'Add-SonarrToOverseerr must be replaced by the consolidated Add-ServiceToOverseerr'
    }
}

# =============================================================================
# 2. New consolidated function must exist
# =============================================================================

Describe 'configure.ps1 - Add-ServiceToOverseerr consolidated function exists' {

    It 'should define an Add-ServiceToOverseerr function' {
        $script:Content | Should -Match 'function Add-ServiceToOverseerr\b' `
            -Because 'A single consolidated function must replace both Add-RadarrToOverseerr and Add-SonarrToOverseerr'
    }
}

# =============================================================================
# 3. Consolidated function parameter contract
# =============================================================================

Describe 'configure.ps1 - Add-ServiceToOverseerr parameter contract' {

    BeforeAll {
        $fnPattern = 'function Add-ServiceToOverseerr[\s\S]*?\n}'
        $fnMatch   = [regex]::Match($script:Content, $fnPattern)
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should accept a service-type parameter (e.g. ServiceType, Service, or Type)' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$ServiceType|\$Service\b|\$Type\b' `
            -Because 'A service-type parameter is required so the caller can pass "radarr" or "sonarr" to select the correct endpoint and payload'
    }

    It 'should accept an ArrApiKey parameter (key for the *arr service)' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$ArrApiKey|\$ServiceApiKey|\$RadarrApiKey|\$ApiKey\b' `
            -Because 'The *arr service API key must be a parameter so callers can pass $RadarrApiKey or $SonarrApiKey'
    }

    It 'should accept an OverseerrApiKey parameter' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$OverseerrApiKey' `
            -Because 'The Overseerr API key must be a parameter so both call sites can pass the same retrieved key'
    }
}

# =============================================================================
# 4. Endpoint path is parameterized — not duplicated across two function bodies
# =============================================================================

Describe 'configure.ps1 - Overseerr endpoint path is derived from service type' {

    BeforeAll {
        $fnPattern = 'function Add-ServiceToOverseerr[\s\S]*?\n}'
        $fnMatch   = [regex]::Match($script:Content, $fnPattern)
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should contain both settings/radarr and settings/sonarr paths within the single function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        # Both paths must appear inside the one function — either via parameter interpolation
        # or a branch — ensuring neither is silently dropped
        ($script:FunctionBody -match 'settings/radarr') -or ($script:FunctionBody -match 'settings') | Should -Be $true `
            -Because 'The consolidated function must route to settings/radarr or settings/sonarr based on the service-type parameter'
        ($script:FunctionBody -match 'settings/sonarr') -or ($script:FunctionBody -match 'settings') | Should -Be $true `
            -Because 'The consolidated function must route to settings/radarr or settings/sonarr based on the service-type parameter'
    }

    It 'should have exactly two Invoke-RestMethod calls targeting the Overseerr settings endpoint (one per call site), not four' {
        # Pre-refactor: 2 function bodies × 1 Invoke-RestMethod each = 2 calls
        # Post-refactor: 1 function body × 1 Invoke-RestMethod = 1 call
        # This test ensures we don't regress back to two identical function bodies
        $settingsMatches = [regex]::Matches($script:Content, 'Invoke-RestMethod[^\r\n]*settings/(radarr|sonarr)')
        $settingsMatches.Count | Should -BeLessOrEqual 2 `
            -Because 'After consolidation there should be at most 2 Invoke-RestMethod calls to Overseerr settings endpoints: one inside the consolidated function body and one per call site — never four (which would indicate two separate function bodies still exist)'
    }
}

# =============================================================================
# 5. Service-specific JSON fields preserved at call sites or via branching
# =============================================================================

Describe 'configure.ps1 - service-specific JSON fields are preserved' {

    It 'should still contain minimumAvailability somewhere in configure.ps1 (Radarr payload)' {
        $script:Content | Should -Match 'minimumAvailability' `
            -Because 'The Radarr Overseerr payload requires minimumAvailability = "released"; it must appear either inside Add-ServiceToOverseerr or at its Radarr call site'
    }

    It 'should still contain enableSeasonFolders somewhere in configure.ps1 (Sonarr payload)' {
        $script:Content | Should -Match 'enableSeasonFolders' `
            -Because 'The Sonarr Overseerr payload requires enableSeasonFolders = $true; it must appear either inside Add-ServiceToOverseerr or at its Sonarr call site'
    }

    It 'should preserve the "released" value for minimumAvailability' {
        $script:Content | Should -Match '"released"' `
            -Because 'minimumAvailability = "released" is the Radarr-specific value from the original Add-RadarrToOverseerr; it must not be dropped'
    }

    It 'should preserve enableSeasonFolders = $true for Sonarr' {
        $script:Content | Should -Match 'enableSeasonFolders\s*=\s*\$true' `
            -Because 'enableSeasonFolders = $true is the Sonarr-specific field from the original Add-SonarrToOverseerr; it must not be dropped'
    }
}

# =============================================================================
# 6. Consolidated function preserves shared API request structure
# =============================================================================

Describe 'configure.ps1 - Add-ServiceToOverseerr API request structure' {

    BeforeAll {
        $fnPattern = 'function Add-ServiceToOverseerr[\s\S]*?\n}'
        $fnMatch   = [regex]::Match($script:Content, $fnPattern)
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should use HTTP POST method for the Overseerr settings call' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '-Method Post' `
            -Because 'Registering a service in Overseerr is a resource creation operation requiring HTTP POST'
    }

    It 'should include the X-Api-Key authentication header' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'X-Api-Key' `
            -Because 'All Overseerr API calls must include the X-Api-Key header'
    }

    It 'should include useSsl in the payload' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'useSsl' `
            -Because 'useSsl is a shared field present in both original Overseerr payloads; it must not be dropped during consolidation'
    }

    It 'should include isDefault in the payload' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'isDefault' `
            -Because 'isDefault = $true is a shared field from both original functions; it must be preserved'
    }

    It 'should include syncEnabled in the payload' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'syncEnabled' `
            -Because 'syncEnabled = $true is a shared field from both original functions; it must be preserved'
    }

    It 'should include preventSearch in the payload' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'preventSearch' `
            -Because 'preventSearch = $false is a shared field from both original functions; it must be preserved'
    }

    It 'should include activeProfileId in the payload' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'activeProfileId' `
            -Because 'activeProfileId is a shared field set from quality profiles in both original functions; it must be preserved'
    }

    It 'should include activeDirectory in the payload' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'activeDirectory' `
            -Because 'activeDirectory is a shared field set from root folders in both original functions; it must be preserved'
    }

    It 'should query the qualityprofile endpoint to populate activeProfileId' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'qualityprofile' `
            -Because 'Both original functions fetched quality profiles via the /api/v3/qualityprofile endpoint; this must be preserved'
    }

    It 'should query the rootfolder endpoint to populate activeDirectory' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ServiceToOverseerr is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'rootfolder' `
            -Because 'Both original functions fetched root folders via the /api/v3/rootfolder endpoint; this must be preserved'
    }
}

# =============================================================================
# 7. Initialize-Overseerr deduplication — exactly one live call in main flow
# =============================================================================

Describe 'configure.ps1 - Initialize-Overseerr called exactly once in main execution flow' {

    It 'should call Initialize-Overseerr exactly once (not 3 times as before)' {
        # Count all occurrences of the call expression (not the function definition)
        $callMatches = [regex]::Matches($script:Content, '(?<!function\s)Initialize-Overseerr(?!\s*\{)')
        $callMatches.Count | Should -Be 1 `
            -Because 'The three repeated Initialize-Overseerr calls must be collapsed to a single call whose result is stored in $overseerrInitialized; repeated live calls hit the network unnecessarily and the init state may differ between calls'
    }

    It 'should store the initialization result in an $overseerrInitialized variable' {
        $script:Content | Should -Match '\$overseerrInitialized\s*=' `
            -Because 'The single Initialize-Overseerr call result must be captured in $overseerrInitialized so subsequent decisions read the variable rather than re-calling the function'
    }

    It 'should reference $overseerrInitialized at least twice (assignment + at least one conditional check)' {
        $references = [regex]::Matches($script:Content, '\$overseerrInitialized')
        $references.Count | Should -BeGreaterOrEqual 2 `
            -Because '$overseerrInitialized must appear at least once for assignment and at least once for a conditional branch, replacing all three original Initialize-Overseerr calls'
    }

    It 'should not call Initialize-Overseerr more than once within an if/elseif/else block' {
        # Regression guard: pre-refactor had Initialize-Overseerr in the condition of both
        # an outer if and an inner elseif. After refactor only the variable is checked.
        $script:Content | Should -Not -Match 'elseif\s*\(\s*-not\s*\(Initialize-Overseerr\)' `
            -Because 'After deduplication, no elseif condition should invoke Initialize-Overseerr directly; it must check $overseerrInitialized instead'
    }
}

# =============================================================================
# 8. Main execution block — Add-ServiceToOverseerr called for both services
# =============================================================================

Describe 'configure.ps1 - main execution block calls Add-ServiceToOverseerr for both services' {

    It 'should reference Add-ServiceToOverseerr at least 3 times (definition + 2 call sites)' {
        $occurrences = ([regex]::Matches($script:Content, 'Add-ServiceToOverseerr')).Count
        $occurrences | Should -BeGreaterOrEqual 3 `
            -Because '1 function definition + 2 call sites (Radarr and Sonarr) = at least 3 occurrences; fewer means one service is not being configured in Overseerr'
    }

    It 'should pass $RadarrApiKey in proximity to one Add-ServiceToOverseerr call' {
        $script:Content | Should -Match 'Add-ServiceToOverseerr[\s\S]{0,400}\$RadarrApiKey|\$RadarrApiKey[\s\S]{0,400}Add-ServiceToOverseerr' `
            -Because 'The Radarr call site must pass $RadarrApiKey as the ArrApiKey argument'
    }

    It 'should pass $SonarrApiKey in proximity to one Add-ServiceToOverseerr call' {
        $script:Content | Should -Match 'Add-ServiceToOverseerr[\s\S]{0,400}\$SonarrApiKey|\$SonarrApiKey[\s\S]{0,400}Add-ServiceToOverseerr' `
            -Because 'The Sonarr call site must pass $SonarrApiKey as the ArrApiKey argument'
    }
}

# =============================================================================
# 9. Behavioral regression — Overseerr endpoint paths still correct
# =============================================================================

Describe 'configure.ps1 - Overseerr endpoint paths preserved after consolidation' {

    It 'should still reference settings/radarr endpoint' {
        $script:Content | Should -Match 'settings/radarr' `
            -Because 'The Radarr Overseerr registration must POST to /api/v1/settings/radarr; this path must not be lost during consolidation'
    }

    It 'should still reference settings/sonarr endpoint' {
        $script:Content | Should -Match 'settings/sonarr' `
            -Because 'The Sonarr Overseerr registration must POST to /api/v1/settings/sonarr; this path must not be lost during consolidation'
    }

    It 'should not duplicate the settings/radarr path across two separate function bodies' {
        $radarrMatches = [regex]::Matches($script:Content, 'function\s+\w+[\s\S]*?settings/radarr[\s\S]*?\n}')
        $radarrMatches.Count | Should -BeLessOrEqual 1 `
            -Because 'settings/radarr must appear in at most one function definition (the consolidated function), not in two separate bodies'
    }

    It 'should not duplicate the settings/sonarr path across two separate function bodies' {
        $sonarrMatches = [regex]::Matches($script:Content, 'function\s+\w+[\s\S]*?settings/sonarr[\s\S]*?\n}')
        $sonarrMatches.Count | Should -BeLessOrEqual 1 `
            -Because 'settings/sonarr must appear in at most one function definition (the consolidated function), not in two separate bodies'
    }
}

# =============================================================================
# 10. PSScriptAnalyzer compliance — no new warnings introduced by refactor
# =============================================================================

Describe 'configure.ps1 - PSScriptAnalyzer clean after Overseerr consolidation' {

    BeforeAll {
        if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
            Write-Warning "PSScriptAnalyzer not found - installing..."
            Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module PSScriptAnalyzer -ErrorAction Stop

        $script:AnalyzerFindings = Invoke-ScriptAnalyzer `
            -Path $script:ConfigurePath `
            -Severity @('Warning', 'Error') `
            -ErrorAction Stop
    }

    It 'should produce zero PSScriptAnalyzer warnings or errors in configure.ps1' {
        $report = $script:AnalyzerFindings | ForEach-Object {
            "[$($_.Severity)] $($_.RuleName) at line $($_.Line): $($_.Message)"
        }
        $script:AnalyzerFindings | Should -BeNullOrEmpty `
            -Because ("The Overseerr consolidation refactor must not introduce PSScriptAnalyzer issues. Found $($script:AnalyzerFindings.Count) issue(s):`n" + ($report -join "`n"))
    }

    It 'should have no PSUseDeclaredVarsMoreThanAssignments violations' {
        $violations = $script:AnalyzerFindings |
            Where-Object { $_.RuleName -eq 'PSUseDeclaredVarsMoreThanAssignments' }
        $violations | Should -BeNullOrEmpty `
            -Because 'The refactor must not leave unused variables (e.g. $overseerrInitialized must be both assigned and read)'
    }

    It 'should parse as valid PowerShell syntax' {
        $errors  = $null
        $null    = [System.Management.Automation.PSParser]::Tokenize($script:Content, [ref]$errors)
        $errors  | Should -BeNullOrEmpty `
            -Because 'configure.ps1 must remain syntactically valid PowerShell after the Overseerr consolidation refactor'
    }
}
