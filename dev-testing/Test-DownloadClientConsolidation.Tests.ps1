#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Download Client Consolidation Tests (Pester)
# =============================================================================
# Validates that Add-QBittorrentToRadarr and Add-QBittorrentToSonarr are
# replaced by a single parameterized Add-QBittorrentDownloadClient function.
#
# Work item: PS: Consolidate Add-QBittorrentToRadarr and Add-QBittorrentToSonarr
#            into Add-QBittorrentDownloadClient
#
# Acceptance criteria tested here:
#   1. Add-QBittorrentToRadarr function no longer exists in configure.ps1
#   2. Add-QBittorrentToSonarr function no longer exists in configure.ps1
#   3. Add-QBittorrentDownloadClient is defined with parameterized field names:
#      ServiceUrl, ApiKey, CategoryFieldName, CategoryValue,
#      ImportedCategoryFieldName, RecentPriorityFieldName, OlderPriorityFieldName
#   4. Exactly one Invoke-RestMethod call targets the /downloadclient endpoint
#      (no duplicated logic between services)
#   5. The consolidated function preserves all JSON body fields from both
#      original functions (no behavioral regression)
#   6. Field names inside the function body use parameter variables, not
#      hardcoded strings like "movieCategory" or "tvCategory"
#   7. The main execution block calls Add-QBittorrentDownloadClient twice,
#      once with Radarr-specific args and once with Sonarr-specific args
#
# TDD: Sections 1, 2, 4, and part of 7 will FAIL on the current codebase
# (old functions still exist, new function does not).
# Sections 3, 5, 6 will SKIP until the new function is defined, then PASS.
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-DownloadClientConsolidation.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent $PSScriptRoot
    $script:ConfigurePath = Join-Path $script:RepoRoot 'configure.ps1'
    $script:Content       = Get-Content -Raw $script:ConfigurePath
}

# =============================================================================
# 1. Old per-service functions must be removed
# =============================================================================

Describe 'configure.ps1 - old per-service download client functions removed' {

    It 'should not contain an Add-QBittorrentToRadarr function definition' {
        $script:Content | Should -Not -Match 'function Add-QBittorrentToRadarr\b' `
            -Because 'Add-QBittorrentToRadarr must be replaced by the consolidated Add-QBittorrentDownloadClient'
    }

    It 'should not contain an Add-QBittorrentToSonarr function definition' {
        $script:Content | Should -Not -Match 'function Add-QBittorrentToSonarr\b' `
            -Because 'Add-QBittorrentToSonarr must be replaced by the consolidated Add-QBittorrentDownloadClient'
    }
}

# =============================================================================
# 2. New consolidated function must exist
# =============================================================================

Describe 'configure.ps1 - Add-QBittorrentDownloadClient consolidated function exists' {

    It 'should define Add-QBittorrentDownloadClient function' {
        $script:Content | Should -Match 'function Add-QBittorrentDownloadClient\b' `
            -Because 'A single consolidated function must replace both Add-QBittorrentToRadarr and Add-QBittorrentToSonarr'
    }
}

# =============================================================================
# 3. Consolidated function parameter contract
# =============================================================================

Describe 'configure.ps1 - Add-QBittorrentDownloadClient parameter contract' {

    BeforeAll {
        # Extract function body for targeted assertions (stops at the first `}`
        # at column 0, which is the function closing brace).
        $fnPattern = 'function Add-QBittorrentDownloadClient[\s\S]*?\n}'
        $fnMatch   = [regex]::Match($script:Content, $fnPattern)
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should accept a ServiceUrl parameter' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$ServiceUrl' `
            -Because 'ServiceUrl must be a parameter so each call site can pass $RadarrUrl or $SonarrUrl'
    }

    It 'should accept an ApiKey parameter' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$ApiKey' `
            -Because 'ApiKey must be a parameter so callers can pass $RadarrApiKey or $SonarrApiKey'
    }

    It 'should accept a CategoryFieldName parameter for the JSON field name' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$CategoryFieldName|\$CategoryName' `
            -Because 'The category field name differs between services (movieCategory vs tvCategory) and must be parameterized'
    }

    It 'should accept a CategoryValue parameter for the JSON field value' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$CategoryValue' `
            -Because 'The category value differs between services ("radarr" vs "sonarr") and must be parameterized'
    }

    It 'should accept an ImportedCategoryFieldName parameter' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$ImportedCategoryFieldName|\$ImportedCategory' `
            -Because 'The imported category field name differs (movieImportedCategory vs tvImportedCategory) and must be parameterized'
    }

    It 'should accept a RecentPriorityFieldName parameter' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$RecentPriorityFieldName|\$RecentPriority' `
            -Because 'The recent priority field name differs (recentMoviePriority vs recentTvPriority) and must be parameterized'
    }

    It 'should accept an OlderPriorityFieldName parameter' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '\$OlderPriorityFieldName|\$OlderPriority' `
            -Because 'The older priority field name differs (olderMoviePriority vs olderTvPriority) and must be parameterized'
    }
}

# =============================================================================
# 4. Single Invoke-RestMethod  -  no duplicate download client logic
# =============================================================================

Describe 'configure.ps1 - single Invoke-RestMethod call for download client registration' {

    It 'should have exactly one Invoke-RestMethod call that targets the downloadclient endpoint' {
        $foundMatches = [regex]::Matches($script:Content, 'Invoke-RestMethod[^\r\n]*downloadclient')
        $foundMatches.Count | Should -Be 1 `
            -Because 'Both services must share a single consolidated function with one Invoke-RestMethod; two calls means the old per-service functions were not removed'
    }

    It 'should use $ServiceUrl in the consolidated Invoke-RestMethod URI' {
        $fnPattern = 'function Add-QBittorrentDownloadClient[\s\S]*?\n}'
        $fnMatch   = [regex]::Match($script:Content, $fnPattern)
        if (-not $fnMatch.Success) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $fnMatch.Value | Should -Match '\$ServiceUrl.*downloadclient|downloadclient.*\$ServiceUrl' `
            -Because 'The consolidated function must build the URI from $ServiceUrl, not from hardcoded $RadarrUrl or $SonarrUrl'
    }
}

# =============================================================================
# 5. Consolidated function sends correct API request structure
# =============================================================================

Describe 'configure.ps1 - Add-QBittorrentDownloadClient API request structure' {

    BeforeAll {
        $fnPattern           = 'function Add-QBittorrentDownloadClient[\s\S]*?\n}'
        $fnMatch             = [regex]::Match($script:Content, $fnPattern)
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should POST to the /api/v3/downloadclient endpoint' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'api/v3/downloadclient' `
            -Because 'The API endpoint must be /api/v3/downloadclient, consistent with the original per-service functions'
    }

    It 'should use HTTP POST method' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '-Method Post' `
            -Because 'Download client registration is a resource creation and must use HTTP POST'
    }

    It 'should include the X-Api-Key authentication header' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'X-Api-Key' `
            -Because 'All *arr API calls must include the X-Api-Key header for authentication'
    }

    It 'should set enable = $true in the request body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'enable\s*=\s*\$true' `
            -Because 'Both original functions enabled the download client; this must be preserved'
    }

    It 'should set protocol to torrent in the request body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'protocol' `
            -Because 'qBittorrent uses the torrent protocol; this field must not be dropped during consolidation'
    }

    It 'should set priority to 1 in the request body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'priority\s*=\s*1' `
            -Because 'Both original functions set priority = 1; this must be preserved in the consolidated body'
    }

    It 'should set removeCompletedDownloads = $true in the request body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'removeCompletedDownloads\s*=\s*\$true' `
            -Because 'Both original functions set removeCompletedDownloads = $true; this must be preserved'
    }

    It 'should set removeFailedDownloads = $true in the request body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'removeFailedDownloads\s*=\s*\$true' `
            -Because 'Both original functions set removeFailedDownloads = $true; this must be preserved'
    }

    It 'should set configContract to QBittorrentSettings' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'QBittorrentSettings' `
            -Because 'configContract must remain QBittorrentSettings to match the original function bodies'
    }

    It 'should set implementation to QBittorrent' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '"QBittorrent"' `
            -Because 'implementation = "QBittorrent" must be preserved from the original function bodies'
    }

    It 'should include the initialState field in the fields array' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'initialState' `
            -Because 'initialState = 0 must be included to produce a JSON body equivalent to the original functions'
    }

    It 'should include the sequentialOrder field in the fields array' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'sequentialOrder' `
            -Because 'sequentialOrder = $false must be preserved to match the original JSON body'
    }

    It 'should include the firstAndLast field in the fields array' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'firstAndLast' `
            -Because 'firstAndLast = $false must be preserved to match the original JSON body'
    }
}

# =============================================================================
# 6. Field names are parameterized - no hardcoding inside function body
# =============================================================================

Describe 'configure.ps1 - service-specific field names are parameterized, not hardcoded' {

    BeforeAll {
        $fnPattern           = 'function Add-QBittorrentDownloadClient[\s\S]*?\n}'
        $fnMatch             = [regex]::Match($script:Content, $fnPattern)
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should not hardcode "movieCategory" as a field name inside the function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Not -Match '"movieCategory"' `
            -Because 'The category field name must come from a parameter ($CategoryFieldName), not be hardcoded as "movieCategory"'
    }

    It 'should not hardcode "tvCategory" as a field name inside the function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Not -Match '"tvCategory"' `
            -Because 'The category field name must come from a parameter, not be hardcoded as "tvCategory"'
    }

    It 'should not hardcode "movieImportedCategory" inside the function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Not -Match '"movieImportedCategory"' `
            -Because 'The imported category field name must come from a parameter, not be hardcoded as "movieImportedCategory"'
    }

    It 'should not hardcode "tvImportedCategory" inside the function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Not -Match '"tvImportedCategory"' `
            -Because 'The imported category field name must come from a parameter, not be hardcoded as "tvImportedCategory"'
    }

    It 'should not hardcode "recentMoviePriority" inside the function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Not -Match '"recentMoviePriority"' `
            -Because 'The recent priority field name must come from a parameter, not be hardcoded as "recentMoviePriority"'
    }

    It 'should not hardcode "recentTvPriority" inside the function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Not -Match '"recentTvPriority"' `
            -Because 'The recent priority field name must come from a parameter, not be hardcoded as "recentTvPriority"'
    }

    It 'should not hardcode "olderMoviePriority" inside the function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Not -Match '"olderMoviePriority"' `
            -Because 'The older priority field name must come from a parameter, not be hardcoded as "olderMoviePriority"'
    }

    It 'should not hardcode "olderTvPriority" inside the function body' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-QBittorrentDownloadClient is not yet defined'
            return
        }
        $script:FunctionBody | Should -Not -Match '"olderTvPriority"' `
            -Because 'The older priority field name must come from a parameter, not be hardcoded as "olderTvPriority"'
    }
}

# =============================================================================
# 7. Main execution block  -  two call sites with correct service-specific args
# =============================================================================

Describe 'configure.ps1 - main execution block calls Add-QBittorrentDownloadClient for both services' {

    It 'should reference Add-QBittorrentDownloadClient at least 3 times (definition + 2 call sites)' {
        $occurrences = ([regex]::Matches($script:Content, 'Add-QBittorrentDownloadClient')).Count
        $occurrences | Should -BeGreaterOrEqual 3 `
            -Because '1 function definition + 2 call sites (Radarr and Sonarr) = at least 3 occurrences; fewer means one service is not being configured'
    }

    It 'should pass "movieCategory" as the category field name for the Radarr call' {
        $script:Content | Should -Match '"movieCategory"' `
            -Because 'The Radarr call site must pass "movieCategory" as the CategoryFieldName argument to match the original Add-QBittorrentToRadarr body'
    }

    It 'should pass "tvCategory" as the category field name for the Sonarr call' {
        $script:Content | Should -Match '"tvCategory"' `
            -Because 'The Sonarr call site must pass "tvCategory" as the CategoryFieldName argument to match the original Add-QBittorrentToSonarr body'
    }

    It 'should pass "movieImportedCategory" for the Radarr call' {
        $script:Content | Should -Match '"movieImportedCategory"' `
            -Because 'The Radarr call must pass "movieImportedCategory" as the ImportedCategoryFieldName to match the original body'
    }

    It 'should pass "tvImportedCategory" for the Sonarr call' {
        $script:Content | Should -Match '"tvImportedCategory"' `
            -Because 'The Sonarr call must pass "tvImportedCategory" as the ImportedCategoryFieldName to match the original body'
    }

    It 'should pass "recentMoviePriority" for the Radarr call' {
        $script:Content | Should -Match '"recentMoviePriority"' `
            -Because 'The Radarr call must pass "recentMoviePriority" as the RecentPriorityFieldName to match the original body'
    }

    It 'should pass "recentTvPriority" for the Sonarr call' {
        $script:Content | Should -Match '"recentTvPriority"' `
            -Because 'The Sonarr call must pass "recentTvPriority" as the RecentPriorityFieldName to match the original body'
    }

    It 'should pass "olderMoviePriority" for the Radarr call' {
        $script:Content | Should -Match '"olderMoviePriority"' `
            -Because 'The Radarr call must pass "olderMoviePriority" as the OlderPriorityFieldName to match the original body'
    }

    It 'should pass "olderTvPriority" for the Sonarr call' {
        $script:Content | Should -Match '"olderTvPriority"' `
            -Because 'The Sonarr call must pass "olderTvPriority" as the OlderPriorityFieldName to match the original body'
    }

    It 'should reference $RadarrApiKey in proximity to the Add-QBittorrentDownloadClient call' {
        # The Radarr call and $RadarrApiKey appear within 300 characters of each other
        $script:Content | Should -Match 'Add-QBittorrentDownloadClient[\s\S]{0,300}\$RadarrApiKey|\$RadarrApiKey[\s\S]{0,300}Add-QBittorrentDownloadClient' `
            -Because 'The Radarr call site must pass $RadarrApiKey as the ApiKey argument'
    }

    It 'should reference $SonarrApiKey in proximity to the Add-QBittorrentDownloadClient call' {
        # The Sonarr call and $SonarrApiKey appear within 300 characters of each other
        $script:Content | Should -Match 'Add-QBittorrentDownloadClient[\s\S]{0,300}\$SonarrApiKey|\$SonarrApiKey[\s\S]{0,300}Add-QBittorrentDownloadClient' `
            -Because 'The Sonarr call site must pass $SonarrApiKey as the ApiKey argument'
    }
}

# =============================================================================
# 8. JSON body value equivalence  -  category values preserved at call sites
# =============================================================================

Describe 'configure.ps1 - JSON body category values preserved at call sites' {

    It 'should pass "radarr" as the category value in the Radarr call' {
        # Original: @{ name = "movieCategory"; value = "radarr" }
        # After consolidation: -CategoryValue "radarr" at the call site
        $script:Content | Should -Match '"radarr"' `
            -Because 'The Radarr call must pass "radarr" as the CategoryValue, matching the original Add-QBittorrentToRadarr body'
    }

    It 'should pass "sonarr" as the category value in the Sonarr call' {
        # Original: @{ name = "tvCategory"; value = "sonarr" }
        # After consolidation: -CategoryValue "sonarr" at the call site
        $script:Content | Should -Match '"sonarr"' `
            -Because 'The Sonarr call must pass "sonarr" as the CategoryValue, matching the original Add-QBittorrentToSonarr body'
    }
}
