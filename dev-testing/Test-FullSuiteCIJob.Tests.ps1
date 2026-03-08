#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Full-Suite CI Job Structural Tests (Pester)
# =============================================================================
# Validates that .github/workflows/ci.yml wires the Bash test suite into
# the full-suite job and adds a parallel PowerShell suite job.
#
# Work item: Wire Bash test suite into CI full-suite job
#
# Acceptance criteria tested here:
#   1. full-suite job runs dev-testing/test.sh on ubuntu-latest
#   2. A parallel job runs dev-testing/test.ps1 via pwsh on ubuntu-latest
#   3. Both test suite jobs depend on fast-gate
#   4. Test logs uploaded as artifacts on failure (actions/upload-artifact + if: failure())
#   5. Both jobs exist by name (enabling them as required status checks)
#   6. No continue-on-error: true suppressing suite failures
#
# TDD: These tests are written BEFORE the implementation exists and MUST fail
# on the current codebase (full-suite still has a placeholder step; no
# PowerShell suite job exists yet).
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-FullSuiteCIJob.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent $PSScriptRoot
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'ci.yml'

    # Cache raw content — null when file is missing (tests skip gracefully)
    $script:WorkflowContent = if (Test-Path $script:WorkflowPath) {
        Get-Content -Raw $script:WorkflowPath
    } else {
        $null
    }

    # Cache content as lines for proximity-based assertions
    $script:WorkflowLines = if ($null -ne $script:WorkflowContent) {
        $script:WorkflowContent -split '\r?\n'
    } else {
        @()
    }
}

# =============================================================================
# Phase 1 — Precondition: ci.yml must exist
# =============================================================================

Describe '.github/workflows/ci.yml — precondition: file exists' {

    It 'should exist at .github/workflows/ci.yml' {
        $script:WorkflowPath | Should -Exist `
            -Because '.github/workflows/ci.yml must be present for any CI job to run'
    }

    It 'should not be empty' {
        $script:WorkflowContent | Should -Not -BeNullOrEmpty `
            -Because 'ci.yml must contain a valid GitHub Actions workflow definition'
    }
}

# =============================================================================
# Phase 2 — full-suite job runs dev-testing/test.sh
# =============================================================================

Describe 'full-suite job — runs dev-testing/test.sh on ubuntu-latest' {

    It 'should reference dev-testing/test.sh in the full-suite job' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match 'dev-testing/test\.sh' `
            -Because (
                'full-suite job must invoke dev-testing/test.sh (the Bash test suite covering ' +
                'phases 1–9 including container startup and live service API integration)'
            )
    }

    It 'should invoke dev-testing/test.sh in a run: step (not just a comment)' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        # Verify the reference to test.sh is not inside a comment-only block.
        # The line must not start with '#' when containing test.sh.
        $testShLines = $script:WorkflowLines |
            Where-Object { $_ -match 'dev-testing/test\.sh' -and $_ -notmatch '^\s*#' }
        $testShLines | Should -Not -BeNullOrEmpty `
            -Because 'dev-testing/test.sh must appear in a run: step, not just in a comment'
    }

    It 'should not still contain the old stub placeholder step' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        # The old placeholder from the earlier work item must be gone
        $stubLines = $script:WorkflowLines |
            Where-Object { $_ -match 'Placeholder.*full container tests.*stub|TODO.*Full container tests.*stub' }
        $stubLines | Should -BeNullOrEmpty `
            -Because (
                'full-suite job must have real test.sh invocation — ' +
                'the earlier placeholder stub must be replaced'
            )
    }

    It 'should run full-suite on ubuntu-latest (Docker is available there for phases 8–9)' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match 'ubuntu-latest' `
            -Because 'full-suite requires ubuntu-latest where Docker is available for container integration tests'
    }

    It 'should have a named step for the test.sh invocation' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match (
            'name:.*[Bb]ash.*[Ss]uite|name:.*[Ff]ull.*[Ss]uite|' +
            'name:.*[Tt]est.*[Ss]uite|name:.*[Rr]un.*test'
        ) `
            -Because 'The test.sh invocation step must be named for clear CI job summary annotations'
    }
}

# =============================================================================
# Phase 3 — full-suite job depends on fast-gate
# =============================================================================

Describe 'full-suite job — depends on fast-gate' {

    It 'should declare "needs: fast-gate" on the full-suite job' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match 'needs:.*fast-gate|needs:\s*\[.*fast-gate' `
            -Because 'full-suite must only run after fast-gate passes (needs: fast-gate)'
    }

    It 'should include a checkout step so repository files are available for testing' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match 'actions/checkout' `
            -Because 'full-suite must check out the repository so dev-testing/test.sh is accessible'
    }
}

# =============================================================================
# Phase 4 — full-suite job — artifact upload on failure
# =============================================================================

Describe 'full-suite job — uploads test logs as artifacts on failure' {

    It 'should use actions/upload-artifact to capture test logs' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match 'actions/upload-artifact' `
            -Because (
                'Test logs must be uploaded as a GitHub Actions artifact so failures ' +
                'can be diagnosed without re-running CI'
            )
    }

    It 'artifact upload step should be conditional on failure using "if: failure()"' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        ($script:WorkflowContent -match 'if:\s*failure\(\)' -or
         $script:WorkflowContent -match 'if:\s*\$\{\{.*failure\(\)') |
            Should -BeTrue `
            -Because (
                'Artifact upload must only run when tests fail (if: failure()) — ' +
                'uploading on every run wastes storage and obscures signal'
            )
    }

    It 'artifact upload step should reference test log files by path or name' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        ($script:WorkflowContent -match 'test[-_]logs|name:.*log|path:.*log' -or
         $script:WorkflowContent -match 'name:.*artifact|path:.*test') |
            Should -BeTrue `
            -Because 'Artifact upload must reference the test log output path (name or path must contain "log" or "test")'
    }

    It 'should have a named step for the artifact upload' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match (
            'name:.*[Uu]pload.*log|name:.*[Uu]pload.*artifact|name:.*[Aa]rtifact|' +
            'name:.*[Tt]est.*log'
        ) `
            -Because 'Artifact upload step must be named for clear CI job summary annotations'
    }
}

# =============================================================================
# Phase 5 — Parallel PowerShell suite job
# =============================================================================

Describe 'parallel PowerShell suite job — runs dev-testing/test.ps1 via pwsh' {

    It 'should define a distinct CI job that runs dev-testing/test.ps1' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match 'dev-testing/test\.ps1' `
            -Because (
                'A parallel CI job must invoke dev-testing/test.ps1 ' +
                '(the PowerShell test suite covering the same phases as test.sh)'
            )
    }

    It 'should use pwsh (PowerShell Core) to run dev-testing/test.ps1' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        ($script:WorkflowContent -match 'shell:\s*pwsh' -or
         $script:WorkflowContent -match 'pwsh.*dev-testing/test\.ps1|pwsh.*test\.ps1') |
            Should -BeTrue `
            -Because (
                'dev-testing/test.ps1 must run under pwsh (PowerShell Core) — ' +
                'either via shell: pwsh in the step, or by invoking pwsh directly'
            )
    }

    It 'should run the PowerShell suite job on ubuntu-latest' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        # ubuntu-latest is required for both suite jobs (Docker for Bash, pwsh for PS)
        $script:WorkflowContent | Should -Match 'ubuntu-latest' `
            -Because 'PowerShell suite job must run on ubuntu-latest (pwsh is installed there)'
    }

    It 'should define the PowerShell suite job with a distinct named job key' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        # Accept common job names for the PowerShell suite
        ($script:WorkflowContent -match 'powershell-suite:|test-powershell:|suite-powershell:|ps-suite:|ps-tests:') |
            Should -BeTrue `
            -Because (
                'PowerShell suite job must have a distinct job key (e.g. powershell-suite:) ' +
                'so it can be added as an independent required status check'
            )
    }

    It 'should have a named step for the test.ps1 invocation' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match (
            'name:.*[Pp]ower[Ss]hell.*[Ss]uite|name:.*[Pp][Ss].*[Ss]uite|' +
            'name:.*[Rr]un.*test\.ps1|name:.*[Pp]ower[Ss]hell.*[Tt]est'
        ) `
            -Because 'PowerShell suite job must have a named step for the test.ps1 invocation'
    }
}

# =============================================================================
# Phase 6 — PowerShell suite job depends on fast-gate
# =============================================================================

Describe 'PowerShell suite job — depends on fast-gate' {

    It 'should declare "needs: fast-gate" on the PowerShell suite job' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Match 'needs:.*fast-gate|needs:\s*\[.*fast-gate' `
            -Because 'PowerShell suite must only run after fast-gate passes (needs: fast-gate)'
    }

    It 'both suite jobs should declare "needs: fast-gate" (two occurrences expected)' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $needsFastGateCount = ($script:WorkflowLines |
            Where-Object { $_ -match 'needs:.*fast-gate' }).Count
        $needsFastGateCount | Should -BeGreaterOrEqual 2 `
            -Because (
                "Both full-suite and the PowerShell suite job must each declare 'needs: fast-gate'. " +
                "Found $needsFastGateCount occurrence(s); expected >= 2."
            )
    }
}

# =============================================================================
# Phase 7 — Both suite jobs named (enabling required status checks)
# =============================================================================

Describe 'CI job names — both suite jobs defined for required status checks' {

    It '"full-suite" job should be defined by name in ci.yml' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowLines | Where-Object { $_ -match '^\s{2}full-suite:' } |
            Should -Not -BeNullOrEmpty `
            -Because (
                "The 'full-suite' job must be defined under jobs: so it can be " +
                'added as a required status check in branch protection settings'
            )
    }

    It 'a distinct PowerShell suite job should be defined by name in ci.yml' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $psJobLine = $script:WorkflowLines |
            Where-Object { $_ -match '^\s{2}(powershell-suite|test-powershell|suite-powershell|ps-suite|ps-tests):' }
        $psJobLine | Should -Not -BeNullOrEmpty `
            -Because (
                'PowerShell suite job must have a named job key (e.g. powershell-suite:) ' +
                'so it can be added as an independent required status check'
            )
    }

    It 'workflow should have at least 8 named steps (suite jobs add named steps)' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $namedSteps = $script:WorkflowLines | Where-Object { $_ -match '^\s+- name:' }
        $namedSteps.Count | Should -BeGreaterOrEqual 8 `
            -Because (
                "Both suite jobs must add named steps, bringing the total to >= 8. " +
                "Found $($namedSteps.Count) named step(s)."
            )
    }
}

# =============================================================================
# Phase 8 — Non-silent failure contract
# =============================================================================

Describe 'CI failure contract — suite jobs must fail loudly' {

    It 'should not use "continue-on-error: true" anywhere in the workflow' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $suppressingLines = $script:WorkflowLines |
            Where-Object { $_ -match 'continue-on-error:\s*true' }
        $suppressingLines | Should -BeNullOrEmpty `
            -Because (
                "'continue-on-error: true' would allow suite failures to pass CI — " +
                'every check must fail the job on non-zero exit'
            )
    }

    It 'should not globally disable shell error propagation with "set +e"' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }
        $script:WorkflowContent | Should -Not -Match 'set \+e' `
            -Because "'set +e' disables error propagation — all shell errors must fail the step"
    }
}

# =============================================================================
# Phase 9 — Acceptance criteria aggregate
# =============================================================================

Describe 'Acceptance criteria — all full-suite CI job requirements satisfied' {

    It 'full-suite runs test.sh, PowerShell suite runs test.ps1, both depend on fast-gate, logs uploaded on failure' {
        if ($null -eq $script:WorkflowContent) {
            Set-ItResult -Skipped -Because 'ci.yml does not exist yet'
            return
        }

        $issues = @()

        # 1. full-suite runs dev-testing/test.sh
        if ($script:WorkflowContent -notmatch 'dev-testing/test\.sh') {
            $issues += 'full-suite does not invoke dev-testing/test.sh'
        }

        # 2. Parallel PowerShell job runs dev-testing/test.ps1 via pwsh
        if ($script:WorkflowContent -notmatch 'dev-testing/test\.ps1') {
            $issues += 'No CI job invokes dev-testing/test.ps1'
        }
        if (-not ($script:WorkflowContent -match 'shell:\s*pwsh' -or
                  $script:WorkflowContent -match 'pwsh.*test\.ps1')) {
            $issues += 'dev-testing/test.ps1 is not run via pwsh'
        }

        # 3. Both jobs depend on fast-gate (>= 2 needs: fast-gate occurrences)
        $needsCount = ($script:WorkflowLines |
            Where-Object { $_ -match 'needs:.*fast-gate' }).Count
        if ($needsCount -lt 2) {
            $issues += "Only $needsCount 'needs: fast-gate' declaration(s) found — both suite jobs require it"
        }

        # 4. Artifact upload on failure
        if ($script:WorkflowContent -notmatch 'actions/upload-artifact') {
            $issues += 'No actions/upload-artifact step found'
        }
        if (-not ($script:WorkflowContent -match 'if:\s*failure\(\)' -or
                  $script:WorkflowContent -match 'if:\s*\$\{\{.*failure\(\)')) {
            $issues += 'Artifact upload is not conditional on failure (if: failure())'
        }

        # 5. Both job keys exist
        if (-not ($script:WorkflowLines | Where-Object { $_ -match '^\s{2}full-suite:' })) {
            $issues += "Missing 'full-suite:' job definition"
        }
        $psJobExists = $script:WorkflowLines |
            Where-Object { $_ -match '^\s{2}(powershell-suite|test-powershell|suite-powershell|ps-suite|ps-tests):' }
        if (-not $psJobExists) {
            $issues += 'Missing distinct PowerShell suite job definition'
        }

        # 6. No continue-on-error suppression
        if ($script:WorkflowContent -match 'continue-on-error:\s*true') {
            $issues += "Found 'continue-on-error: true' — suite failures must not be suppressed"
        }

        $report = $issues -join '; '
        $issues | Should -BeNullOrEmpty `
            -Because "All acceptance criteria must be satisfied. Issues: $report"
    }
}
