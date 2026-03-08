#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# README CI Badge and Development Section Tests (Pester)
# =============================================================================
# Validates that README.md contains a CI status badge using the correct GitHub
# Actions badge URL format, positioned before the Early Release Notice callout,
# and that a Development section references the test suite and CI requirement.
#
# Work item: Add CI status badge to README
#
# Acceptance criteria tested here:
#   1. README.md contains a CI badge with the correct GitHub Actions badge URL format
#   2. Badge uses correct markdown image syntax
#   3. Badge is wrapped in a link to the CI workflow page
#   4. Badge is positioned before the Early Release Notice callout
#   5. Badge appears in the header section (first 15 lines)
#   6. A Development section references dev-testing/test.ps1
#   7. The Development section mentions CI must pass before merging
#
# TDD: These tests are written BEFORE the implementation exists and MUST fail
# on the current codebase until README.md is updated.
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-ReadmeBadge.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ReadmePath = Join-Path $script:RepoRoot 'readme.md'

    # GitHub repository details  -  must match the actual repository
    $script:RepoOwner    = 'parsoFish'
    $script:RepoName     = 'simplarr'
    $script:WorkflowFile = 'ci.yml'

    $script:BadgeImageUrl   = "https://github.com/$($script:RepoOwner)/$($script:RepoName)/actions/workflows/$($script:WorkflowFile)/badge.svg"
    $script:WorkflowPageUrl = "https://github.com/$($script:RepoOwner)/$($script:RepoName)/actions/workflows/$($script:WorkflowFile)"

    # Cache raw content  -  null when file is missing (tests must fail gracefully)
    $script:ReadmeContent = if (Test-Path $script:ReadmePath) {
        Get-Content -Raw $script:ReadmePath
    } else {
        $null
    }

    # Cache content as lines for line-by-line and position assertions
    $script:ReadmeLines = if ($null -ne $script:ReadmeContent) {
        $script:ReadmeContent -split '\r?\n'
    } else {
        @()
    }
}

# =============================================================================
# Phase 1  -  File existence
# =============================================================================

Describe 'readme.md  -  file existence' {

    It 'should exist at the project root' {
        $script:ReadmePath | Should -Exist `
            -Because 'readme.md must be present at the project root'
    }

    It 'should not be empty' {
        $script:ReadmeContent | Should -Not -BeNullOrEmpty `
            -Because 'readme.md must contain project documentation'
    }
}

# =============================================================================
# Phase 2  -  CI badge presence and format
# =============================================================================

Describe 'CI badge  -  presence and correct format' {

    It 'should contain the GitHub Actions badge image URL for ci.yml' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }
        $script:ReadmeContent | Should -Match [regex]::Escape($script:BadgeImageUrl) `
            -Because "README must contain the CI badge image URL: $($script:BadgeImageUrl)"
    }

    It 'should use markdown image syntax for the CI badge' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }
        # Standard markdown image: ![alt text](url)
        $script:ReadmeContent | Should -Match ('!\[.*?\]\(' + [regex]::Escape($script:BadgeImageUrl) + '\)') `
            -Because 'CI badge must use markdown image syntax: ![CI](badge_url)'
    }

    It 'should reference the ci.yml workflow file in the badge URL' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }
        $script:ReadmeContent | Should -Match [regex]::Escape($script:WorkflowFile) `
            -Because "Badge URL must reference the '$($script:WorkflowFile)' workflow file"
    }
}

# =============================================================================
# Phase 3  -  CI badge link (badge must be clickable)
# =============================================================================

Describe 'CI badge  -  clickable link to workflow page' {

    It 'should wrap the badge image in a link to the CI workflow page' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }
        # Clickable badge: [![alt](badge_url)](workflow_url)
        $expectedPattern = '\[!\[.*?\]\(' + [regex]::Escape($script:BadgeImageUrl) + '\)\]\(' + [regex]::Escape($script:WorkflowPageUrl) + '\)'
        $script:ReadmeContent | Should -Match $expectedPattern `
            -Because "Badge must link to the Actions workflow page: $($script:WorkflowPageUrl)"
    }

    It 'should link to the correct repository and workflow page' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }
        $script:ReadmeContent | Should -Match [regex]::Escape($script:WorkflowPageUrl) `
            -Because "Badge link must point to $($script:WorkflowPageUrl)"
    }
}

# =============================================================================
# Phase 4  -  Badge position (before Early Release Notice)
# =============================================================================

Describe 'CI badge  -  position in README' {

    It 'should appear before the Early Release Notice callout' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }

        # Find line numbers (1-based)
        $badgeLine = ($script:ReadmeLines |
            Select-String -Pattern [regex]::Escape($script:BadgeImageUrl) |
            Select-Object -First 1).LineNumber

        $earlyReleaseLine = ($script:ReadmeLines |
            Select-String -Pattern 'Early Release Notice' |
            Select-Object -First 1).LineNumber

        $badgeLine | Should -Not -BeNullOrEmpty `
            -Because 'CI badge must exist in README before checking position'

        $earlyReleaseLine | Should -Not -BeNullOrEmpty `
            -Because "'Early Release Notice' callout must exist in README before checking badge position"

        $badgeLine | Should -BeLessThan $earlyReleaseLine `
            -Because "CI badge (line $badgeLine) must appear BEFORE the Early Release Notice callout (line $earlyReleaseLine)"
    }

    It 'should appear in the header section within the first 15 lines' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }

        $badgeLine = ($script:ReadmeLines |
            Select-String -Pattern [regex]::Escape($script:BadgeImageUrl) |
            Select-Object -First 1).LineNumber

        $badgeLine | Should -Not -BeNullOrEmpty `
            -Because 'CI badge must exist in README'

        $badgeLine | Should -BeLessOrEqual 15 `
            -Because (
                "CI badge must be visible near the project header (within the first 15 lines). " +
                "Found at line $badgeLine."
            )
    }
}

# =============================================================================
# Phase 5  -  Development section content
# =============================================================================

Describe 'Development section  -  test suite and CI requirement' {

    It 'should contain a Development section heading' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }
        $script:ReadmeContent | Should -Match '(?m)^#+\s+(Development|Development & Testing|Contributing)' `
            -Because 'README must contain a Development section so contributors know how to contribute'
    }

    It 'should reference dev-testing/test.ps1 in the Development section' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }
        $script:ReadmeContent | Should -Match 'dev-testing/test\.ps1' `
            -Because (
                'Development section must reference dev-testing/test.ps1 so contributors ' +
                'know how to run the automated test suite before submitting changes'
            )
    }

    It 'should state that CI must pass before merging' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }
        $ciMentioned = (
            $script:ReadmeContent -imatch 'CI must pass' -or
            $script:ReadmeContent -imatch 'CI.*must.*pass' -or
            $script:ReadmeContent -imatch 'CI.*pass.*before.*merg' -or
            $script:ReadmeContent -imatch 'must pass.*before.*merg' -or
            $script:ReadmeContent -imatch 'CI.*required.*merg' -or
            $script:ReadmeContent -imatch 'pass.*CI.*before'
        )
        $ciMentioned | Should -BeTrue `
            -Because (
                'Development section must explicitly state that CI must pass before merging, ' +
                'so contributors know the quality gate requirement'
            )
    }
}

# =============================================================================
# Phase 6  -  Aggregate acceptance criteria
# =============================================================================

Describe 'Acceptance criteria  -  all README badge requirements satisfied' {

    It 'badge exists, links correctly, is positioned in header, before Early Release Notice' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }

        $issues = @()

        # Badge image URL present
        if ($script:ReadmeContent -notmatch [regex]::Escape($script:BadgeImageUrl)) {
            $issues += "Missing CI badge image URL: $($script:BadgeImageUrl)"
        }

        # Badge has markdown image syntax
        if ($script:ReadmeContent -notmatch ('!\[.*?\]\(' + [regex]::Escape($script:BadgeImageUrl) + '\)')) {
            $issues += 'CI badge must use markdown image syntax: ![CI](badge_url)'
        }

        # Badge is wrapped in a link
        $expectedPattern = '\[!\[.*?\]\(' + [regex]::Escape($script:BadgeImageUrl) + '\)\]\(' + [regex]::Escape($script:WorkflowPageUrl) + '\)'
        if ($script:ReadmeContent -notmatch $expectedPattern) {
            $issues += "Badge must link to: $($script:WorkflowPageUrl)"
        }

        # Badge is before Early Release Notice
        $badgeLine = ($script:ReadmeLines |
            Select-String -Pattern [regex]::Escape($script:BadgeImageUrl) |
            Select-Object -First 1).LineNumber
        $earlyReleaseLine = ($script:ReadmeLines |
            Select-String -Pattern 'Early Release Notice' |
            Select-Object -First 1).LineNumber

        if ($null -ne $badgeLine -and $null -ne $earlyReleaseLine -and $badgeLine -ge $earlyReleaseLine) {
            $issues += "Badge (line $badgeLine) must appear before Early Release Notice (line $earlyReleaseLine)"
        }

        # Badge is in header section
        if ($null -ne $badgeLine -and $badgeLine -gt 15) {
            $issues += "Badge (line $badgeLine) must be within the first 15 lines"
        }

        $report = $issues -join '; '
        $issues | Should -BeNullOrEmpty `
            -Because "All badge acceptance criteria must pass. Issues: $report"
    }

    It 'Development section references test suite and CI requirement' {
        if ($null -eq $script:ReadmeContent) {
            Set-ItResult -Skipped -Because 'readme.md does not exist'
            return
        }

        $issues = @()

        if ($script:ReadmeContent -notmatch '(?m)^#+\s+(Development|Development & Testing|Contributing)') {
            $issues += 'Missing Development section heading'
        }

        if ($script:ReadmeContent -notmatch 'dev-testing/test\.ps1') {
            $issues += 'Development section must reference dev-testing/test.ps1'
        }

        $ciMentioned = (
            $script:ReadmeContent -imatch 'CI must pass' -or
            $script:ReadmeContent -imatch 'CI.*must.*pass' -or
            $script:ReadmeContent -imatch 'CI.*pass.*before.*merg' -or
            $script:ReadmeContent -imatch 'must pass.*before.*merg' -or
            $script:ReadmeContent -imatch 'CI.*required.*merg'
        )
        if (-not $ciMentioned) {
            $issues += 'Development section must mention CI must pass before merging'
        }

        $report = $issues -join '; '
        $issues | Should -BeNullOrEmpty `
            -Because "All Development section criteria must pass. Issues: $report"
    }
}
