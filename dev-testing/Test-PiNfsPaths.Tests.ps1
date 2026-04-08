#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Pi Compose NFS Path Assertions (Pester)
# =============================================================================
# Validates that docker-compose-pi.yml declares all three required NFS
# host-side paths that the Pi/Server split-setup depends on, AND that
# test.ps1 contains the equivalent Select-String-based validation logic.
#
# Mirrors the Bash test_pi_nfs_paths.sh (same PASS/FAIL outcomes, PS parity).
#
# Required NFS host-side paths:
#   /mnt/nas/downloads   — download landing zone (radarr, sonarr)
#   /mnt/nas/movies      — movies library (radarr, tautulli)
#   /mnt/nas/tv          — TV library (sonarr, tautulli)
#
# Test phases:
#   1  File Existence            — docker-compose-pi.yml must be present
#   2  NFS Path Presence         — all three /mnt/nas/* paths are declared as
#                                  host-side volume sources (Select-String)
#   3  Per-Service Volume Bindings — each service block contains its required
#                                    NFS volume bindings (regression guard)
#   4  test.ps1 Integration      — test.ps1 contains Select-String-based NFS
#                                  path validation in its structural-validation
#                                  section (TDD: FAIL before implementation)
#
# TDD: Phase 4 tests FAIL on the current codebase because test.ps1 does not
# yet contain any /mnt/nas Select-String checks for docker-compose-pi.yml.
# Phases 1-3 verify the compose file itself (expected PASS once the compose
# file has all three paths declared).
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-PiNfsPaths.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
#
# No Docker dependency — all assertions are pure file content checks.
# =============================================================================

BeforeAll {
    $script:RepoRoot    = Split-Path -Parent $PSScriptRoot
    $script:PiCompose   = Join-Path $script:RepoRoot 'docker-compose-pi.yml'
    $script:TestPs1     = Join-Path $script:RepoRoot 'dev-testing' 'test.ps1'

    $script:PiContent   = if (Test-Path $script:PiCompose) {
        Get-Content -Path $script:PiCompose
    } else {
        $null
    }

    $script:TestContent = if (Test-Path $script:TestPs1) {
        Get-Content -Raw $script:TestPs1
    } else {
        $null
    }

    # Lines of test.ps1 as an array for proximity checks
    $script:TestLines   = if ($null -ne $script:TestContent) {
        $script:TestContent -split '\r?\n'
    } else {
        @()
    }
}

# =============================================================================
# Phase 1 — File Existence
# =============================================================================

Describe 'Phase 1 - File existence' {

    It 'docker-compose-pi.yml should exist at the repository root' {
        $script:PiCompose | Should -Exist `
            -Because 'docker-compose-pi.yml must be present before NFS path validation can run'
    }
}

# =============================================================================
# Phase 2 — NFS Host Path Presence (Select-String content checks)
#
# Each of the three paths must appear as a host-side volume source.
# A valid binding line looks like:
#     - /mnt/nas/downloads:/downloads
# The colon immediately after the path distinguishes the host-side source
# from a container-side path or a comment.
#
# TDD note: These tests PASS once all three NFS paths are declared in
# docker-compose-pi.yml.  They FAIL if any path is absent.
# =============================================================================

Describe 'Phase 2 - NFS host path presence in docker-compose-pi.yml' {

    BeforeAll {
        if ($null -eq $script:PiContent) {
            $script:SkipReason = 'docker-compose-pi.yml not found'
        } else {
            $script:SkipReason = $null
        }
    }

    It 'should declare /mnt/nas/downloads as a host-side volume source' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        $match = $script:PiContent |
            Select-String -Pattern '^\s+-\s+/mnt/nas/downloads:'
        $match | Should -Not -BeNullOrEmpty `
            -Because (
                'docker-compose-pi.yml must declare /mnt/nas/downloads as a host-side ' +
                'volume source (e.g. "- /mnt/nas/downloads:/downloads"). ' +
                'Absence means the volume binding maps to a non-existent host path, ' +
                'breaking radarr and sonarr media ingestion.'
            )
    }

    It 'should declare /mnt/nas/movies as a host-side volume source' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        $match = $script:PiContent |
            Select-String -Pattern '^\s+-\s+/mnt/nas/movies:'
        $match | Should -Not -BeNullOrEmpty `
            -Because (
                'docker-compose-pi.yml must declare /mnt/nas/movies as a host-side ' +
                'volume source (e.g. "- /mnt/nas/movies:/movies"). ' +
                'Absence breaks radarr library access and tautulli play history.'
            )
    }

    It 'should declare /mnt/nas/tv as a host-side volume source' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        $match = $script:PiContent |
            Select-String -Pattern '^\s+-\s+/mnt/nas/tv:'
        $match | Should -Not -BeNullOrEmpty `
            -Because (
                'docker-compose-pi.yml must declare /mnt/nas/tv as a host-side ' +
                'volume source (e.g. "- /mnt/nas/tv:/tv"). ' +
                'Absence breaks sonarr library access and tautulli play history.'
            )
    }
}

# =============================================================================
# Phase 3 — Per-Service Volume Binding Completeness
#
# Each service that must access NAS media is asserted to have the correct
# host-side mounts within its own service block.  This prevents a path being
# present in one service but silently missing from another (which would still
# pass Phase 2 but break that service).
#
# Expected bindings:
#   radarr   → /mnt/nas/downloads, /mnt/nas/movies
#   sonarr   → /mnt/nas/downloads, /mnt/nas/tv
#   tautulli → /mnt/nas/movies,    /mnt/nas/tv
# =============================================================================

Describe 'Phase 3 - Per-service NFS volume bindings in docker-compose-pi.yml' {

    BeforeAll {
        if ($null -eq $script:PiContent) {
            $script:SkipReason = 'docker-compose-pi.yml not found'
            $script:ServiceBlocks = @{}
            return
        }
        $script:SkipReason = $null

        # Extract each service's indented block by scanning lines.
        # A service block starts at '  <service>:' (2-space indent, no leading dash)
        # and ends at the next top-level service line or end of file.
        $serviceBlocks = @{}
        $currentService = $null
        $blockLines     = [System.Collections.Generic.List[string]]::new()

        foreach ($line in $script:PiContent) {
            if ($line -match '^  ([a-z][a-z0-9_-]+):(\s*$|\s+#)') {
                # Flush the previous service block
                if ($null -ne $currentService) {
                    $serviceBlocks[$currentService] = $blockLines.ToArray()
                }
                $currentService = $Matches[1]
                $blockLines     = [System.Collections.Generic.List[string]]::new()
            } elseif ($null -ne $currentService) {
                $blockLines.Add($line)
            }
        }
        # Flush the final service block
        if ($null -ne $currentService) {
            $serviceBlocks[$currentService] = $blockLines.ToArray()
        }

        $script:ServiceBlocks = $serviceBlocks
    }

    Context 'radarr service' {

        It 'radarr should bind /mnt/nas/downloads for media ingestion' {
            if ($null -ne $script:SkipReason) {
                Set-ItResult -Skipped -Because $script:SkipReason
                return
            }
            $block = $script:ServiceBlocks['radarr']
            $block | Should -Not -BeNullOrEmpty `
                -Because 'radarr service block must exist in docker-compose-pi.yml'

            $match = $block | Select-String -Pattern '^\s+-\s+/mnt/nas/downloads:'
            $match | Should -Not -BeNullOrEmpty `
                -Because 'radarr service block must bind /mnt/nas/downloads so radarr can access completed downloads'
        }

        It 'radarr should bind /mnt/nas/movies for library access' {
            if ($null -ne $script:SkipReason) {
                Set-ItResult -Skipped -Because $script:SkipReason
                return
            }
            $block = $script:ServiceBlocks['radarr']
            $block | Should -Not -BeNullOrEmpty `
                -Because 'radarr service block must exist in docker-compose-pi.yml'

            $match = $block | Select-String -Pattern '^\s+-\s+/mnt/nas/movies:'
            $match | Should -Not -BeNullOrEmpty `
                -Because 'radarr service block must bind /mnt/nas/movies so radarr can manage the movies library'
        }
    }

    Context 'sonarr service' {

        It 'sonarr should bind /mnt/nas/downloads for media ingestion' {
            if ($null -ne $script:SkipReason) {
                Set-ItResult -Skipped -Because $script:SkipReason
                return
            }
            $block = $script:ServiceBlocks['sonarr']
            $block | Should -Not -BeNullOrEmpty `
                -Because 'sonarr service block must exist in docker-compose-pi.yml'

            $match = $block | Select-String -Pattern '^\s+-\s+/mnt/nas/downloads:'
            $match | Should -Not -BeNullOrEmpty `
                -Because 'sonarr service block must bind /mnt/nas/downloads so sonarr can access completed downloads'
        }

        It 'sonarr should bind /mnt/nas/tv for library access' {
            if ($null -ne $script:SkipReason) {
                Set-ItResult -Skipped -Because $script:SkipReason
                return
            }
            $block = $script:ServiceBlocks['sonarr']
            $block | Should -Not -BeNullOrEmpty `
                -Because 'sonarr service block must exist in docker-compose-pi.yml'

            $match = $block | Select-String -Pattern '^\s+-\s+/mnt/nas/tv:'
            $match | Should -Not -BeNullOrEmpty `
                -Because 'sonarr service block must bind /mnt/nas/tv so sonarr can manage the TV library'
        }
    }

    Context 'tautulli service' {

        It 'tautulli should bind /mnt/nas/movies for play history statistics' {
            if ($null -ne $script:SkipReason) {
                Set-ItResult -Skipped -Because $script:SkipReason
                return
            }
            $block = $script:ServiceBlocks['tautulli']
            $block | Should -Not -BeNullOrEmpty `
                -Because 'tautulli service block must exist in docker-compose-pi.yml'

            $match = $block | Select-String -Pattern '^\s+-\s+/mnt/nas/movies:'
            $match | Should -Not -BeNullOrEmpty `
                -Because 'tautulli service block must bind /mnt/nas/movies for play history and statistics'
        }

        It 'tautulli should bind /mnt/nas/tv for play history statistics' {
            if ($null -ne $script:SkipReason) {
                Set-ItResult -Skipped -Because $script:SkipReason
                return
            }
            $block = $script:ServiceBlocks['tautulli']
            $block | Should -Not -BeNullOrEmpty `
                -Because 'tautulli service block must exist in docker-compose-pi.yml'

            $match = $block | Select-String -Pattern '^\s+-\s+/mnt/nas/tv:'
            $match | Should -Not -BeNullOrEmpty `
                -Because 'tautulli service block must bind /mnt/nas/tv for play history and statistics'
        }
    }
}

# =============================================================================
# Phase 4 — test.ps1 Integration (TDD — FAILS before implementation)
#
# test.ps1 must contain Select-String-based NFS path validation in its
# structural-validation section (equivalent to test.sh Phase 2b).
#
# Checked invariants:
#   4.1  test.ps1 references /mnt/nas/downloads in an NFS path check
#   4.2  test.ps1 references /mnt/nas/movies in an NFS path check
#   4.3  test.ps1 references /mnt/nas/tv in an NFS path check
#   4.4  test.ps1 references docker-compose-pi.yml in the same NFS context
#        (not only in the compose-config phase or syntax-validation phase)
#   4.5  test.ps1 uses Select-String (or content matching) to validate
#        the NFS paths — not a mere string presence check via -match on
#        the whole file
#   4.6  test.ps1 calls Write-Fail (not only Write-Skip) for missing NFS
#        paths, ensuring the suite exits 1 when paths are absent
#
# TDD: All six assertions FAIL on the current codebase because test.ps1
# does not yet contain any NFS path Select-String validation block.
# =============================================================================

Describe 'Phase 4 - test.ps1 NFS path validation (TDD — fails before implementation)' {

    BeforeAll {
        if ($null -eq $script:TestContent) {
            $script:SkipReason = 'test.ps1 not found'
        } else {
            $script:SkipReason = $null
        }
    }

    It '4.1 - test.ps1 should check /mnt/nas/downloads against docker-compose-pi.yml' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }
        $script:TestContent | Should -Match '/mnt/nas/downloads' `
            -Because (
                'test.ps1 must validate that /mnt/nas/downloads is declared as a ' +
                'host-side volume source in docker-compose-pi.yml (split-setup NFS check). ' +
                'This is the PS equivalent of the bash grep check in test.sh Phase 2b.'
            )
    }

    It '4.2 - test.ps1 should check /mnt/nas/movies against docker-compose-pi.yml' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }
        $script:TestContent | Should -Match '/mnt/nas/movies' `
            -Because (
                'test.ps1 must validate that /mnt/nas/movies is declared as a ' +
                'host-side volume source in docker-compose-pi.yml (split-setup NFS check).'
            )
    }

    It '4.3 - test.ps1 should check /mnt/nas/tv against docker-compose-pi.yml' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }
        $script:TestContent | Should -Match '/mnt/nas/tv' `
            -Because (
                'test.ps1 must validate that /mnt/nas/tv is declared as a ' +
                'host-side volume source in docker-compose-pi.yml (split-setup NFS check).'
            )
    }

    It '4.4 - test.ps1 should reference docker-compose-pi.yml near the NFS path checks' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        # Strategy: find line indices for docker-compose-pi.yml references that are
        # NOT in the required-files list, file-existence check, or docker compose
        # syntax-validation block (those already exist).  Then find the first
        # /mnt/nas reference line and verify it is within 30 lines of an NFS-context
        # pi-compose reference.
        #
        # We look for a docker-compose-pi.yml mention that co-occurs with /mnt/nas
        # content: either on the same line or within a 30-line sliding window.

        $piLine = $script:TestLines |
            Select-String -Pattern 'docker-compose-pi\.yml' |
            Where-Object { $_.Line -notmatch 'REQUIRED_FILES|requiredFiles|Test-Path|docker compose\s+-f\s+docker-compose-pi\.yml' } |
            Select-Object -First 1

        $nfsLine = $script:TestLines |
            Select-String -Pattern '/mnt/nas' |
            Select-Object -First 1

        $piLine  | Should -Not -BeNullOrEmpty `
            -Because (
                'test.ps1 must reference docker-compose-pi.yml in an NFS validation context ' +
                '(beyond the existing required-files list and syntax-validation block). ' +
                'The NFS Select-String check must name the source file for clear failure messages.'
            )

        $nfsLine | Should -Not -BeNullOrEmpty `
            -Because 'test.ps1 must contain at least one /mnt/nas path reference for NFS validation'

        if ($null -ne $piLine -and $null -ne $nfsLine) {
            $delta = [Math]::Abs($nfsLine.LineNumber - $piLine.LineNumber)
            $delta | Should -BeLessOrEqual 30 `
                -Because (
                    "The docker-compose-pi.yml reference and /mnt/nas path checks must appear " +
                    "within 30 lines of each other in test.ps1 (structural-validation section). " +
                    "Current distance: $delta lines. This ensures they form a coherent NFS validation block."
                )
        }
    }

    It '4.5 - test.ps1 should use Select-String (or equivalent content match) for NFS path validation' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        # The implementation must use content-aware matching (Select-String, -match, or
        # Get-Content piped to Where-Object) rather than just passing a known string.
        # We verify that a Select-String call or -match expression appears in the same
        # region of test.ps1 as the /mnt/nas path references.

        $nfsLineNumbers = @(
            $script:TestLines |
                Select-String -Pattern '/mnt/nas' |
                Select-Object -ExpandProperty LineNumber
        )

        $nfsLineNumbers | Should -Not -BeNullOrEmpty `
            -Because 'test.ps1 must contain /mnt/nas path references (prerequisite for 4.5)'

        if ($nfsLineNumbers.Count -gt 0) {
            $firstNfsLine = $nfsLineNumbers[0]
            # Examine the 20 lines surrounding the first /mnt/nas reference for a
            # content-matching call (Select-String, -match, Where-Object, or -like).
            $windowStart = [Math]::Max(0, $firstNfsLine - 10)
            $windowEnd   = [Math]::Min($script:TestLines.Count - 1, $firstNfsLine + 10)
            $window      = $script:TestLines[$windowStart..$windowEnd] -join "`n"

            $hasContentMatch = (
                $window -match 'Select-String'      -or
                $window -match '\-match\s'           -or
                $window -match 'Where-Object\s*\{'  -or
                $window -match '\-like\s'
            )
            $hasContentMatch | Should -BeTrue `
                -Because (
                    'test.ps1 must use Select-String, -match, Where-Object, or equivalent ' +
                    'to check that each /mnt/nas path appears as a host-side volume source ' +
                    'in docker-compose-pi.yml. A simple string constant is not sufficient.'
                )
        }
    }

    It '4.6 - test.ps1 should call Write-Fail (not only Write-Skip) for missing NFS paths' {
        if ($null -ne $script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        # Write-Fail must appear near the /mnt/nas checks so that the suite exits 1
        # when a path is absent.  Using only Write-Skip would silently pass the suite
        # and defeat the purpose of the NFS validation.

        $nfsLineNumbers = @(
            $script:TestLines |
                Select-String -Pattern '/mnt/nas' |
                Select-Object -ExpandProperty LineNumber
        )

        $nfsLineNumbers | Should -Not -BeNullOrEmpty `
            -Because 'test.ps1 must contain /mnt/nas path references (prerequisite for 4.6)'

        if ($nfsLineNumbers.Count -gt 0) {
            $firstNfsLine = $nfsLineNumbers[0]
            $windowStart  = [Math]::Max(0, $firstNfsLine - 5)
            $windowEnd    = [Math]::Min($script:TestLines.Count - 1, $firstNfsLine + 15)
            $window       = $script:TestLines[$windowStart..$windowEnd] -join "`n"

            $window | Should -Match 'Write-Fail' `
                -Because (
                    'test.ps1 NFS path checks must call Write-Fail when a path is missing from ' +
                    'docker-compose-pi.yml, so that the test suite exits 1 and the CI pipeline ' +
                    'catches the broken volume binding. Write-Skip alone would allow the suite to pass.'
                )
        }
    }
}

# =============================================================================
# Acceptance Criteria — aggregate (mirrors work-item definition of done)
# =============================================================================

Describe 'Acceptance criteria - PS/Bash parity for split-setup NFS coverage' {

    It 'all three NFS paths should be present in docker-compose-pi.yml' {
        if ($null -eq $script:PiContent) {
            Set-ItResult -Skipped -Because 'docker-compose-pi.yml not found'
            return
        }

        $nfsPaths = @('/mnt/nas/downloads', '/mnt/nas/movies', '/mnt/nas/tv')
        $missing  = $nfsPaths | Where-Object {
            $path    = $_
            $escaped = [regex]::Escape($path)
            -not ($script:PiContent | Select-String -Pattern "^\s+-\s+${escaped}:")
        }

        $missing | Should -BeNullOrEmpty `
            -Because (
                "docker-compose-pi.yml must declare all three NFS host-side volume sources. " +
                "Missing: $($missing -join ', '). " +
                "Absent paths cause silent volume-binding failures that break media ingestion."
            )
    }

    It 'test.ps1 should validate all three NFS paths (Select-String parity with test.sh)' {
        if ($null -eq $script:TestContent) {
            Set-ItResult -Skipped -Because 'test.ps1 not found'
            return
        }

        $nfsPaths = @('/mnt/nas/downloads', '/mnt/nas/movies', '/mnt/nas/tv')
        $missing  = $nfsPaths | Where-Object { $script:TestContent -notmatch [regex]::Escape($_) }

        $missing | Should -BeNullOrEmpty `
            -Because (
                "test.ps1 must reference all three NFS paths for PS/Bash parity with test.sh. " +
                "Missing references: $($missing -join ', '). " +
                "Without these checks, the PS test suite provides weaker split-setup coverage than Bash."
            )
    }
}
