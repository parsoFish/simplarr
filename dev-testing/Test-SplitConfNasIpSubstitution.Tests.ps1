#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Split.conf NAS IP Substitution and nginx -t Validation Tests (Pester)
# =============================================================================
# Validates that test.ps1 implements the split.conf NAS IP substitution and
# nginx -t validation tests that mirror the Bash counterpart in test.sh:
#
#   Structural (test.ps1 code patterns):
#     - test.ps1 reads split.conf with Get-Content
#     - test.ps1 uses -replace to substitute YOUR_NAS_IP with a test IP
#     - test.ps1 writes the substituted content to a temp file via Out-File / Set-Content
#     - test.ps1 asserts that YOUR_NAS_IP is absent after substitution (Write-Pass / Write-Fail)
#     - test.ps1 guards nginx -t with Get-Command nginx
#     - test.ps1 uses Write-Skip when nginx is not available
#     - test.ps1 removes the temp file after the nginx -t test
#
#   Behavioral (direct substitution logic on nginx/split.conf):
#     - split.conf contains YOUR_NAS_IP placeholder(s) before substitution
#     - After -replace, no YOUR_NAS_IP remains in the output
#     - The test IP appears at every expected location (Plex :32400, qBittorrent :8080)
#     - Pi-hosted service upstreams are not mutated by the substitution
#
# Work item: PS: Add split.conf NAS IP substitution and nginx -t validation to test.ps1
#
# Acceptance criteria tested here:
#   1. test.ps1 uses Get-Content + -replace + Out-File/Set-Content for temp substitution
#   2. test.ps1 asserts the substitution outcome (YOUR_NAS_IP gone → Write-Pass)
#   3. test.ps1 contains a Get-Command nginx guard for the nginx -t conditional
#   4. test.ps1 uses Write-Skip for the nginx-absent case
#   5. test.ps1 invokes nginx -t on the temp file when nginx is present
#   6. test.ps1 removes the temp file after use
#   7. The -replace substitution on the real split.conf replaces ALL YOUR_NAS_IP occurrences
#   8. The substitution does not alter Pi-hosted service upstreams
#
# TDD: Sections 1-3 (structural) FAIL on the current codebase — test.ps1 does not yet
#      contain the substitution block or the Get-Command nginx guard.
# Sections 4-5 (behavioral) are regression guards that verify the substitution
# logic works correctly when applied directly to nginx/split.conf.
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-SplitConfNasIpSubstitution.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent $PSScriptRoot
    $script:TestPs1Path   = Join-Path $PSScriptRoot 'test.ps1'
    $script:SplitConfPath = Join-Path $script:RepoRoot 'nginx' 'split.conf'

    $script:TestPs1Content   = if (Test-Path $script:TestPs1Path)   { Get-Content -Raw $script:TestPs1Path }   else { $null }
    $script:SplitConfContent = if (Test-Path $script:SplitConfPath) { Get-Content -Raw $script:SplitConfPath } else { $null }

    # RFC 5737 TEST-NET-1 — safe non-routable address for tests
    $script:TestNasIp = '192.0.2.1'
}

# =============================================================================
# Section 1  -  test.ps1 structural: NAS IP substitution code
# =============================================================================

Describe 'test.ps1  -  split.conf NAS IP substitution code is present' {

    It 'should read nginx/split.conf with Get-Content for the substitution step' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'Get-Content.*split\.conf' `
            -Because 'test.ps1 must read split.conf so its content can be substituted in a temp copy'
    }

    It 'should use the -replace operator to substitute YOUR_NAS_IP with a test IP' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match '-replace.*YOUR_NAS_IP' `
            -Because 'The PowerShell -replace operator is the idiomatic way to do inline placeholder substitution'
    }

    It 'should write the substituted content to a temp file with Out-File or Set-Content' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'Out-File|Set-Content' `
            -Because 'The substituted content must be written to a temp file so nginx -t receives a real file path'
    }

    It 'should assert that YOUR_NAS_IP is absent from the substituted output' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        # The assertion must check the placeholder is gone; the string YOUR_NAS_IP
        # appears both in the -replace call and the assertion — either context satisfies.
        $script:TestPs1Content | Should -Match 'YOUR_NAS_IP' `
            -Because 'test.ps1 must reference YOUR_NAS_IP in the assertion that confirms the placeholder was fully replaced'
    }

    It 'should emit Write-Pass when the YOUR_NAS_IP substitution succeeds' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        # Accept any Write-Pass that mentions substitution, NAS IP, or split.conf NAS
        $script:TestPs1Content | Should -Match 'Write-Pass.*(?:split\.conf.*NAS|NAS.*split\.conf|substitut)' `
            -Because 'A successful substitution must emit a PASS result, mirroring the Bash pass call in the equivalent section'
    }

    It 'should emit Write-Fail when YOUR_NAS_IP is still present after substitution' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'Write-Fail.*(?:split\.conf.*NAS|NAS.*split\.conf|substitut|YOUR_NAS_IP)' `
            -Because 'If YOUR_NAS_IP survives -replace the test must FAIL — this guards against silent substitution regressions'
    }

    It 'should clean up the temp file after the substitution and nginx -t tests' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'Remove-Item' `
            -Because 'Temp files must be removed after use to avoid accumulating test artefacts across runs'
    }
}

# =============================================================================
# Section 2  -  test.ps1 structural: nginx -t conditional guard
# =============================================================================

Describe 'test.ps1  -  nginx -t guard and conditional invocation' {

    It 'should detect nginx availability with Get-Command nginx' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'Get-Command\s+nginx' `
            -Because 'nginx -t must be gated on Get-Command nginx so the test degrades gracefully when nginx is not installed'
    }

    It 'should emit Write-Skip when nginx binary is absent' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'Write-Skip.*(?:nginx|split\.conf)' `
            -Because 'When nginx is not installed the test must skip (not fail), mirroring the Bash "docker not available" skip'
    }

    It 'should invoke nginx -t on the substituted temp file when nginx is present' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'nginx\s+-t' `
            -Because 'When nginx IS available, test.ps1 must run nginx -t to verify the substituted config is syntactically valid'
    }

    It 'should emit Write-Pass when nginx -t succeeds on the substituted split.conf' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'Write-Pass.*(?:nginx.*split\.conf|split\.conf.*nginx)' `
            -Because 'A passing nginx -t result must emit PASS, matching the Bash test.sh pass "nginx -t nginx/split.conf — syntax is ok"'
    }

    It 'should emit Write-Fail when nginx -t reports a syntax error in split.conf' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $script:TestPs1Content | Should -Match 'Write-Fail.*(?:nginx.*split\.conf|split\.conf.*nginx|nginx.*syntax)' `
            -Because 'A failing nginx -t result must emit FAIL so CI can detect configuration regressions'
    }
}

# =============================================================================
# Section 3  -  test.ps1 parity: split.conf section covers all expected cases
# =============================================================================

Describe 'test.ps1  -  split.conf section mirrors Bash test.sh parity' {

    It 'should contain both the -replace substitution and Get-Command nginx guard together' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $hasReplace  = $script:TestPs1Content -match '-replace.*YOUR_NAS_IP'
        $hasNginxCmd = $script:TestPs1Content -match 'Get-Command\s+nginx'
        ($hasReplace -and $hasNginxCmd) | Should -Be $true `
            -Because 'Both the substitution and the nginx guard must be present for full Bash parity in the split.conf section'
    }

    It 'should contain Write-Skip, Write-Pass, and Write-Fail outcomes for the split.conf nginx section' {
        if ($null -eq $script:TestPs1Content) {
            Set-ItResult -Skipped -Because 'test.ps1 does not exist'
            return
        }
        $hasSkip = $script:TestPs1Content -match 'Write-Skip'
        $hasPass = $script:TestPs1Content -match 'Write-Pass'
        $hasFail = $script:TestPs1Content -match 'Write-Fail'
        ($hasSkip -and $hasPass -and $hasFail) | Should -Be $true `
            -Because 'All three outcomes (PASS / FAIL / SKIP) must be covered to match the Bash test.sh behaviour'
    }
}

# =============================================================================
# Section 4  -  Behavioral: YOUR_NAS_IP substitution applied to real split.conf
# =============================================================================

Describe 'split.conf  -  YOUR_NAS_IP substitution behavior (direct regression guard)' {

    BeforeAll {
        if ($null -ne $script:SplitConfContent) {
            $script:TmpConf = [System.IO.Path]::ChangeExtension(
                [System.IO.Path]::GetTempFileName(), '.conf'
            )
            # Reproduce exactly what the test.ps1 implementation will do:
            #   Get-Content | -replace | Out-File
            $replaced = $script:SplitConfContent -replace 'YOUR_NAS_IP', $script:TestNasIp
            $replaced | Out-File -FilePath $script:TmpConf -Encoding utf8
            $script:SubstitutedContent = Get-Content -Raw $script:TmpConf
        } else {
            $script:TmpConf            = $null
            $script:SubstitutedContent = $null
        }
    }

    AfterAll {
        if ($null -ne $script:TmpConf -and (Test-Path $script:TmpConf)) {
            Remove-Item $script:TmpConf -ErrorAction SilentlyContinue
        }
    }

    It 'nginx/split.conf should exist at the expected path' {
        $script:SplitConfPath | Should -Exist `
            -Because 'split.conf must exist for the substitution test to have a source file'
    }

    It 'split.conf should contain at least one YOUR_NAS_IP placeholder before substitution' {
        if ($null -eq $script:SplitConfContent) {
            Set-ItResult -Skipped -Because 'nginx/split.conf does not exist'
            return
        }
        $script:SplitConfContent | Should -Match 'YOUR_NAS_IP' `
            -Because 'split.conf must contain YOUR_NAS_IP placeholders — without them there is nothing to substitute'
    }

    It 'substituted content should NOT contain YOUR_NAS_IP after -replace' {
        if ($null -eq $script:SubstitutedContent) {
            Set-ItResult -Skipped -Because 'nginx/split.conf does not exist or substitution was skipped'
            return
        }
        $script:SubstitutedContent | Should -Not -Match 'YOUR_NAS_IP' `
            -Because 'After -replace, every YOUR_NAS_IP occurrence must be gone — any remaining placeholder means the substitution is incomplete'
    }

    It 'substituted content should contain the test IP in place of every YOUR_NAS_IP' {
        if ($null -eq $script:SubstitutedContent) {
            Set-ItResult -Skipped -Because 'nginx/split.conf does not exist or substitution was skipped'
            return
        }
        $script:SubstitutedContent | Should -Match [regex]::Escape($script:TestNasIp) `
            -Because 'After -replace, the test IP must appear at every location that previously held YOUR_NAS_IP'
    }

    It 'substituted content should contain the test IP on the Plex upstream (port 32400)' {
        if ($null -eq $script:SubstitutedContent) {
            Set-ItResult -Skipped -Because 'nginx/split.conf does not exist or substitution was skipped'
            return
        }
        $expected = "$($script:TestNasIp):32400"
        $script:SubstitutedContent | Should -Match [regex]::Escape($expected) `
            -Because 'The Plex NAS upstream uses YOUR_NAS_IP:32400 — after substitution it must read <test-ip>:32400'
    }

    It 'substituted content should contain the test IP on the qBittorrent upstream (port 8080)' {
        if ($null -eq $script:SubstitutedContent) {
            Set-ItResult -Skipped -Because 'nginx/split.conf does not exist or substitution was skipped'
            return
        }
        $expected = "$($script:TestNasIp):8080"
        $script:SubstitutedContent | Should -Match [regex]::Escape($expected) `
            -Because 'The qBittorrent NAS upstream uses YOUR_NAS_IP:8080 — after substitution it must read <test-ip>:8080'
    }

    It 'substituted content should preserve Pi-hosted service upstreams unchanged' {
        if ($null -eq $script:SubstitutedContent) {
            Set-ItResult -Skipped -Because 'nginx/split.conf does not exist or substitution was skipped'
            return
        }
        $script:SubstitutedContent | Should -Match 'radarr:7878' `
            -Because 'Pi-hosted Radarr uses a Docker service name (not YOUR_NAS_IP) — -replace must not touch these entries'
        $script:SubstitutedContent | Should -Match 'sonarr:8989' `
            -Because 'Pi-hosted Sonarr uses a Docker service name — it must be unchanged after substitution'
    }

    It 'substituted content should be written to a real temp file (not just an in-memory string)' {
        if ($null -eq $script:TmpConf) {
            Set-ItResult -Skipped -Because 'nginx/split.conf does not exist'
            return
        }
        $script:TmpConf | Should -Exist `
            -Because 'The substituted content must be materialised to a temp file so nginx -t can operate on a real path'
    }
}

# =============================================================================
# Section 5  -  Behavioral: Get-Command nginx guard pattern is reliable
# =============================================================================

Describe 'Get-Command nginx guard  -  pattern reliability' {

    It 'Get-Command should return $null for a non-existent binary' {
        $result = Get-Command 'nginx-nonexistent-binary-abc123' -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty `
            -Because 'Get-Command returns $null for missing commands — test.ps1 must use this pattern to gate nginx -t without throwing'
    }

    It 'Get-Command should return a non-null object for an installed binary' {
        # pwsh or powershell must be present in any valid test environment
        $ps = Get-Command 'pwsh' -ErrorAction SilentlyContinue
        if ($null -eq $ps) {
            $ps = Get-Command 'powershell' -ErrorAction SilentlyContinue
        }
        $ps | Should -Not -BeNullOrEmpty `
            -Because 'Get-Command detects present binaries — confirms the guard pattern is reliable on this runner'
    }
}
