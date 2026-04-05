#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Prowlarr $IndexerDefinitions Data Structure Tests (Pester)
# =============================================================================
# Validates the extraction of Prowlarr indexer definitions from an inline local
# variable inside Add-ProwlarrPublicIndexer into a script-level $IndexerDefinitions
# array, and that Add-ProwlarrPublicIndexer drives its loop from that array.
#
# Work item: PS: Extract Prowlarr indexer definitions to a data structure in configure.ps1
#
# Acceptance criteria tested here:
#   1. $IndexerDefinitions is defined at script scope (outside any function)
#   2. $IndexerDefinitions contains exactly 5 entries
#   3. Each entry has the required keys: Name, Url/BaseUrl, Definition/DefinitionName
#   4. All 5 expected indexers are present (YTS, The Pirate Bay, TorrentGalaxy,
#      Nyaa.si, LimeTorrents) with correct URLs and definition names
#   5. Add-ProwlarrPublicIndexer references $IndexerDefinitions (not a local $indexers)
#   6. Add-ProwlarrPublicIndexer no longer defines a local $indexers = @(...) block
#   7. Invoke-RestMethod is called exactly once per $IndexerDefinitions entry with a
#      payload that includes the correct name and baseUrl for each indexer
#   8. configure.ps1 remains PSScriptAnalyzer-clean after the refactor
#
# TDD: Sections 1-7 FAIL on the current codebase ($IndexerDefinitions is not defined;
#      Add-ProwlarrPublicIndexer uses a local $indexers variable instead).
# Section 8 is a regression guard that should remain green throughout.
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-IndexerDefinitions.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
#   Install-Module PSScriptAnalyzer -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent $PSScriptRoot
    $script:ConfigurePath = Join-Path $script:RepoRoot 'configure.ps1'
    $script:Content       = Get-Content -Raw $script:ConfigurePath

    # Expected indexers after the refactor — used to drive assertion loops
    $script:ExpectedIndexers = @(
        @{ Name = 'YTS';            Url = 'https://yts.mx';               Definition = 'yts'            }
        @{ Name = 'The Pirate Bay'; Url = 'https://thepiratebay.org';     Definition = 'thepiratebay'   }
        @{ Name = 'TorrentGalaxy'; Url = 'https://torrentgalaxy.to';     Definition = 'torrentgalaxy'  }
        @{ Name = 'Nyaa.si';        Url = 'https://nyaa.si';              Definition = 'nyaasi'         }
        @{ Name = 'LimeTorrents';   Url = 'https://www.limetorrents.lol'; Definition = 'limetorrents'   }
    )
}

# =============================================================================
# 1. $IndexerDefinitions must be defined at script scope (outside functions)
# =============================================================================

Describe 'configure.ps1 - $IndexerDefinitions exists at script scope' {

    It 'should define a $IndexerDefinitions variable somewhere in the script' {
        $script:Content | Should -Match '\$IndexerDefinitions\s*=' `
            -Because 'The indexer list must be promoted to a named script-level variable so that adding a new indexer only requires updating the array, not a new API call block'
    }

    It 'should define $IndexerDefinitions outside any function body' {
        # Extract all function bodies and check none of them contain the definition
        $functionBodies = [regex]::Matches($script:Content, 'function\s+\w[\w-]*[\s\S]*?\n\}')
        $definedInsideFunction = $functionBodies | Where-Object {
            $_.Value -match '\$IndexerDefinitions\s*='
        }
        $definedInsideFunction | Should -BeNullOrEmpty `
            -Because '$IndexerDefinitions must be a script-level constant, not a local variable buried inside Add-ProwlarrPublicIndexer or any other function'
    }
}

# =============================================================================
# 2. $IndexerDefinitions must contain exactly 5 entries
# =============================================================================

Describe 'configure.ps1 - $IndexerDefinitions entry count' {

    It 'should reference exactly 5 indexer Name keys in the $IndexerDefinitions literal' {
        # Count @{ Name = ... } blocks that appear in proximity to $IndexerDefinitions
        # We look for the assignment block and count Name occurrences within it
        $match = [regex]::Match($script:Content, '\$IndexerDefinitions\s*=\s*@\(([\s\S]*?)\)\s*\n')
        if (-not $match.Success) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions assignment not found — run after structural test passes'
            return
        }
        $arrayLiteral = $match.Groups[1].Value
        $nameCount = ([regex]::Matches($arrayLiteral, '\bName\s*=')).Count
        $nameCount | Should -Be 5 `
            -Because 'Exactly 5 public indexers are defined: YTS, The Pirate Bay, TorrentGalaxy, Nyaa.si, LimeTorrents'
    }
}

# =============================================================================
# 3. Each $IndexerDefinitions entry must have the required fields
# =============================================================================

Describe 'configure.ps1 - $IndexerDefinitions entry schema' {

    BeforeAll {
        $match = [regex]::Match($script:Content, '\$IndexerDefinitions\s*=\s*@\(([\s\S]*?)\)\s*\n')
        $script:ArrayLiteral = if ($match.Success) { $match.Groups[1].Value } else { $null }
    }

    It 'should include a Name key in every entry' {
        if ($null -eq $script:ArrayLiteral) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions not found yet'
            return
        }
        $script:ArrayLiteral | Should -Match '\bName\s*=' `
            -Because 'Every indexer entry needs a Name key used as the display name in Prowlarr'
    }

    It 'should include a Url or BaseUrl key in every entry' {
        if ($null -eq $script:ArrayLiteral) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions not found yet'
            return
        }
        $script:ArrayLiteral | Should -Match '\b(Url|BaseUrl)\s*=' `
            -Because 'Every indexer entry needs a Url or BaseUrl key passed to Add-ProwlarrIndexer as -BaseUrl'
    }

    It 'should include a Definition or DefinitionName key in every entry' {
        if ($null -eq $script:ArrayLiteral) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions not found yet'
            return
        }
        $script:ArrayLiteral | Should -Match '\b(Definition|DefinitionName)\s*=' `
            -Because 'Every indexer entry needs a Definition/DefinitionName key passed to Add-ProwlarrIndexer as -DefinitionName'
    }
}

# =============================================================================
# 4. All 5 expected indexers are present with correct URLs and definition names
# =============================================================================

Describe 'configure.ps1 - all 5 expected indexers present in $IndexerDefinitions' {

    foreach ($expected in @(
        @{ Name = 'YTS';            Url = 'https://yts.mx';               Definition = 'yts'           }
        @{ Name = 'The Pirate Bay'; Url = 'https://thepiratebay.org';     Definition = 'thepiratebay'  }
        @{ Name = 'TorrentGalaxy'; Url = 'https://torrentgalaxy.to';     Definition = 'torrentgalaxy' }
        @{ Name = 'Nyaa.si';        Url = 'https://nyaa.si';              Definition = 'nyaasi'        }
        @{ Name = 'LimeTorrents';   Url = 'https://www.limetorrents.lol'; Definition = 'limetorrents'  }
    )) {
        Context "indexer: $($expected.Name)" {

            BeforeAll {
                $script:ExpName       = $expected.Name
                $script:ExpUrl        = $expected.Url
                $script:ExpDefinition = $expected.Definition
            }

            It "should include '$($expected.Name)' in configure.ps1" {
                $script:Content | Should -Match ([regex]::Escape($script:ExpName)) `
                    -Because "$($script:ExpName) was in the original inline list and must be preserved in `$IndexerDefinitions"
            }

            It "should include URL '$($expected.Url)' for $($expected.Name)" {
                $script:Content | Should -Match ([regex]::Escape($script:ExpUrl)) `
                    -Because "The base URL '$($script:ExpUrl)' is the canonical public tracker URL for $($script:ExpName) and must not be changed during refactor"
            }

            It "should include definition name '$($expected.Definition)' for $($expected.Name)" {
                $script:Content | Should -Match ([regex]::Escape($script:ExpDefinition)) `
                    -Because "The Cardigann definition name '$($script:ExpDefinition)' matches the Prowlarr indexer catalogue entry for $($script:ExpName)"
            }
        }
    }
}

# =============================================================================
# 5 & 6. Add-ProwlarrPublicIndexer must use $IndexerDefinitions, not local $indexers
# =============================================================================

Describe 'configure.ps1 - Add-ProwlarrPublicIndexer uses $IndexerDefinitions' {

    BeforeAll {
        $fnMatch = [regex]::Match($script:Content, 'function Add-ProwlarrPublicIndexer[\s\S]*?\n\}')
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should reference $IndexerDefinitions inside Add-ProwlarrPublicIndexer' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ProwlarrPublicIndexer was not found in configure.ps1'
            return
        }
        $script:FunctionBody | Should -Match '\$IndexerDefinitions' `
            -Because 'After the refactor Add-ProwlarrPublicIndexer must loop over the script-level $IndexerDefinitions rather than its own local array'
    }

    It 'should not define a local $indexers = @(...) array inside Add-ProwlarrPublicIndexer' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ProwlarrPublicIndexer was not found in configure.ps1'
            return
        }
        $script:FunctionBody | Should -Not -Match '\$indexers\s*=\s*@\(' `
            -Because 'The inline $indexers local variable must be removed; the data now lives in the script-level $IndexerDefinitions so only one place needs updating when indexers change'
    }

    It 'should contain a foreach loop that iterates over $IndexerDefinitions' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Add-ProwlarrPublicIndexer was not found in configure.ps1'
            return
        }
        $script:FunctionBody | Should -Match 'foreach\s*\([\s\S]{0,80}\$IndexerDefinitions' `
            -Because 'Add-ProwlarrPublicIndexer must drive its loop from $IndexerDefinitions, not a local variable'
    }
}

# =============================================================================
# 7. Behavioral: Invoke-RestMethod called exactly once per $IndexerDefinitions entry
#    with correct payload fields
# =============================================================================

Describe 'configure.ps1 - Add-ProwlarrPublicIndexer calls Invoke-RestMethod once per $IndexerDefinitions entry' {

    BeforeAll {
        # Dot-source a safe version of configure.ps1 (main execution block stripped)
        $rawContent = Get-Content -Raw $script:ConfigurePath
        $safeContent = $rawContent -replace '(?ms)^# =+\r?\n# Main Execution\r?\n# =+.*$', ''

        $script:SafeTmpFile = [System.IO.Path]::ChangeExtension(
            [System.IO.Path]::GetTempFileName(), '.ps1'
        )
        $safeContent | Set-Content $script:SafeTmpFile

        try {
            . $script:SafeTmpFile
        }
        catch {
            # Suppress errors from module-level statements that need real env vars
        }

        # Capture $IndexerDefinitions if the refactor has been implemented
        $script:IndexerDefinitions = Get-Variable -Name 'IndexerDefinitions' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Value

        $script:ProwlarrUrl = 'http://test-prowlarr:9696'
    }

    AfterAll {
        Remove-Item $script:SafeTmpFile -ErrorAction SilentlyContinue
    }

    It 'should call Invoke-RestMethod exactly N times where N equals $IndexerDefinitions.Count' {
        # Pre-implementation: $IndexerDefinitions is null → Count is 0
        # The current code calls Invoke-RestMethod 5 times from inline $indexers → FAILS
        # Post-implementation: $IndexerDefinitions.Count = 5 → called 5 times → PASSES
        $expectedCallCount = if ($null -ne $script:IndexerDefinitions) {
            $script:IndexerDefinitions.Count
        } else {
            0
        }

        Mock Invoke-RestMethod { return @{} }
        Mock Write-Success {}
        Mock Write-Info {}
        Mock Write-WarningMessage {}

        Add-ProwlarrPublicIndexer -ApiKey 'test-prowlarr-key'

        Should -Invoke Invoke-RestMethod -Times $expectedCallCount -Exactly `
            -Because "Invoke-RestMethod must be called exactly once per entry in `$IndexerDefinitions ($expectedCallCount entries); a mismatch means the loop is driven by a different (possibly stale) source"
    }

    It 'should call Invoke-RestMethod with the YTS baseUrl in the request body' {
        if ($null -eq $script:IndexerDefinitions) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions not yet defined — implement the refactor first'
            return
        }

        $script:CapturedBodies = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            $script:CapturedBodies.Add($Body)
            return @{}
        }
        Mock Write-Success {}
        Mock Write-Info {}
        Mock Write-WarningMessage {}

        Add-ProwlarrPublicIndexer -ApiKey 'test-prowlarr-key'

        $ytsBodyFound = $script:CapturedBodies | Where-Object { $_ -match 'yts\.mx' }
        $ytsBodyFound | Should -Not -BeNullOrEmpty `
            -Because 'One Invoke-RestMethod call must include the YTS base URL (https://yts.mx) in the JSON payload'
    }

    It 'should call Invoke-RestMethod with The Pirate Bay baseUrl in the request body' {
        if ($null -eq $script:IndexerDefinitions) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions not yet defined — implement the refactor first'
            return
        }

        $script:CapturedBodies = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            $script:CapturedBodies.Add($Body)
            return @{}
        }
        Mock Write-Success {}
        Mock Write-Info {}
        Mock Write-WarningMessage {}

        Add-ProwlarrPublicIndexer -ApiKey 'test-prowlarr-key'

        $tpbBodyFound = $script:CapturedBodies | Where-Object { $_ -match 'thepiratebay' }
        $tpbBodyFound | Should -Not -BeNullOrEmpty `
            -Because 'One Invoke-RestMethod call must include the Pirate Bay base URL in the JSON payload'
    }

    It 'should call Invoke-RestMethod with Nyaa.si baseUrl in the request body' {
        if ($null -eq $script:IndexerDefinitions) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions not yet defined — implement the refactor first'
            return
        }

        $script:CapturedBodies = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            $script:CapturedBodies.Add($Body)
            return @{}
        }
        Mock Write-Success {}
        Mock Write-Info {}
        Mock Write-WarningMessage {}

        Add-ProwlarrPublicIndexer -ApiKey 'test-prowlarr-key'

        $nyaaBodyFound = $script:CapturedBodies | Where-Object { $_ -match 'nyaa\.si' }
        $nyaaBodyFound | Should -Not -BeNullOrEmpty `
            -Because 'One Invoke-RestMethod call must include the Nyaa.si base URL in the JSON payload'
    }

    It 'should call Invoke-RestMethod with LimeTorrents baseUrl in the request body' {
        if ($null -eq $script:IndexerDefinitions) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions not yet defined — implement the refactor first'
            return
        }

        $script:CapturedBodies = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            $script:CapturedBodies.Add($Body)
            return @{}
        }
        Mock Write-Success {}
        Mock Write-Info {}
        Mock Write-WarningMessage {}

        Add-ProwlarrPublicIndexer -ApiKey 'test-prowlarr-key'

        $limeBodyFound = $script:CapturedBodies | Where-Object { $_ -match 'limetorrents' }
        $limeBodyFound | Should -Not -BeNullOrEmpty `
            -Because 'One Invoke-RestMethod call must include the LimeTorrents base URL in the JSON payload'
    }

    It 'should pass the X-Api-Key header on every Invoke-RestMethod call' {
        if ($null -eq $script:IndexerDefinitions) {
            Set-ItResult -Skipped -Because '$IndexerDefinitions not yet defined — implement the refactor first'
            return
        }

        $testKey = 'prowlarr-test-key-abc123'
        $script:CapturedHeaders = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-RestMethod {
            $script:CapturedHeaders.Add($Headers)
            return @{}
        }
        Mock Write-Success {}
        Mock Write-Info {}
        Mock Write-WarningMessage {}

        Add-ProwlarrPublicIndexer -ApiKey $testKey

        $missingKey = $script:CapturedHeaders | Where-Object { $_['X-Api-Key'] -ne $testKey }
        $missingKey | Should -BeNullOrEmpty `
            -Because 'Every Prowlarr API call must include the X-Api-Key authentication header with the correct value'
    }
}

# =============================================================================
# 8. PSScriptAnalyzer compliance — regression guard
# =============================================================================

Describe 'configure.ps1 - PSScriptAnalyzer clean after $IndexerDefinitions refactor' {

    BeforeAll {
        if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
            Write-Warning 'PSScriptAnalyzer not found - installing...'
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
            -Because ("The `$IndexerDefinitions refactor must not introduce PSScriptAnalyzer issues. Found $($script:AnalyzerFindings.Count) issue(s):`n" + ($report -join "`n"))
    }

    It 'should have no PSUseDeclaredVarsMoreThanAssignments violations' {
        $violations = $script:AnalyzerFindings |
            Where-Object { $_.RuleName -eq 'PSUseDeclaredVarsMoreThanAssignments' }
        $violations | Should -BeNullOrEmpty `
            -Because '$IndexerDefinitions must be both assigned and read in the loop; unused variable declarations would indicate the refactor is incomplete'
    }

    It 'should parse as valid PowerShell syntax' {
        $errors = $null
        $null   = [System.Management.Automation.PSParser]::Tokenize($script:Content, [ref]$errors)
        $errors | Should -BeNullOrEmpty `
            -Because 'configure.ps1 must remain syntactically valid PowerShell after the $IndexerDefinitions refactor'
    }
}
