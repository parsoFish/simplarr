#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Invoke-ConfigApi Status-Code Classification Tests (Pester)
# =============================================================================
# Validates the Invoke-ConfigApi helper function that wraps Invoke-RestMethod
# and returns a structured result object { Success, StatusCode, Body, AlreadyExists }.
#
# Work item: PS: Implement Invoke-ConfigApi helper with status-code classification
#
# Classification rules:
#   201/200       → Success=$true,  AlreadyExists=$false  (logged at info level)
#   409 Conflict  → Success=$true,  AlreadyExists=$true   (logged at info level, NOT warning)
#   4xx/5xx       → Success=$false, StatusCode + Body surfaced in Write-Warning message
#   Timeout/Error → Success=$false, warning logged
#
# Acceptance criteria tested here:
#   1. Invoke-ConfigApi is defined in configure.ps1
#   2. Return object has exactly the four properties: Success, StatusCode, Body, AlreadyExists
#   3. Function wraps Invoke-RestMethod internally
#   4. Function has a try/catch for error handling
#   5. 201 response  → Success=$true, AlreadyExists=$false
#   6. 200 response  → Success=$true, AlreadyExists=$false
#   7. 409 response  → Success=$true, AlreadyExists=$true, NO Write-Warning emitted
#   8. 400 response  → Success=$false, Write-Warning contains "400"
#   9. 400 response  → Write-Warning message contains the response body
#  10. 500 response  → Success=$false, Write-Warning contains "500"
#  11. 500 response  → Write-Warning message contains the response body
#  12. Timeout       → Success=$false, Write-Warning emitted
#  13. configure.ps1 remains PSScriptAnalyzer-clean after adding Invoke-ConfigApi
#
# TDD: Sections 1-4 will FAIL on the current codebase (function not yet defined).
# Sections 5-12 will FAIL until the implementation exists.
# Section 13 will PASS on current code, must continue to PASS after implementation.
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-InvokeConfigApi.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
#   Install-Module PSScriptAnalyzer -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent $PSScriptRoot
    $script:ConfigurePath = Join-Path $script:RepoRoot 'configure.ps1'
    $script:Content       = Get-Content -Raw $script:ConfigurePath

    # ---------------------------------------------------------------------------
    # Load Invoke-ConfigApi and its logging dependencies from configure.ps1 via
    # AST extraction so that the main execution block is not run during tests.
    # ---------------------------------------------------------------------------
    $tokens = $null
    $errors = $null
    $ast    = [System.Management.Automation.Language.Parser]::ParseInput(
        $script:Content, [ref]$tokens, [ref]$errors
    )

    $helperNames = @(
        'Write-Info',
        'Write-WarningMessage',
        'Write-ErrorMessage',
        'Write-Success',
        'Invoke-ConfigApi'
    )

    $funcDefs = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in $helperNames
    }, $true)

    foreach ($fn in $funcDefs) {
        try {
            Invoke-Expression $fn.Extent.Text
        }
        catch {
            Write-Warning "Could not load function '$($fn.Name)': $_"
        }
    }

    $script:FunctionLoaded = $null -ne (Get-Command 'Invoke-ConfigApi' -ErrorAction SilentlyContinue)

    # ---------------------------------------------------------------------------
    # Exception factory — creates an ErrorRecord that mimics how Invoke-RestMethod
    # surfaces HTTP error responses in PowerShell 7 (HttpResponseException).
    # Falls back to a plain Exception with the status code in the message when
    # running in environments that don't have Microsoft.PowerShell.Commands.
    # ---------------------------------------------------------------------------
    function script:New-MockHttpErrorRecord {
        param(
            [Parameter(Mandatory)]
            [int]$StatusCode,
            [string]$Body = '{}'
        )
        $httpStatus  = [System.Net.HttpStatusCode]$StatusCode
        $reasonPhrase = $httpStatus.ToString()
        $message      = "Response status code does not indicate success: $StatusCode ($reasonPhrase)."

        try {
            # Build a real HttpResponseMessage so the exception is structurally identical
            # to what Invoke-RestMethod throws in PowerShell 7.
            $httpResponse = [System.Net.Http.HttpResponseMessage]::new($httpStatus)
            $exType       = [Microsoft.PowerShell.Commands.HttpResponseException]
            $ex           = [Activator]::CreateInstance($exType, $message, $httpResponse)
        }
        catch {
            # Fallback: plain Exception with status code embedded in message so
            # implementations that use regex extraction still work.
            $ex = [System.Exception]::new("HTTP $StatusCode : $message")
        }

        $errRecord = [System.Management.Automation.ErrorRecord]::new(
            $ex,
            "HttpError$StatusCode",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null
        )
        # Set ErrorDetails.Message to the response body — this is how PS7 surfaces
        # the response body for non-2xx responses from Invoke-RestMethod.
        $errRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body)
        return $errRecord
    }

    # Factory for network timeout exceptions (no HTTP response at all).
    function script:New-MockTimeoutErrorRecord {
        $ex        = [System.OperationCanceledException]::new('The request timed out.')
        $errRecord = [System.Management.Automation.ErrorRecord]::new(
            $ex,
            'RequestTimeout',
            [System.Management.Automation.ErrorCategory]::OperationTimeout,
            $null
        )
        return $errRecord
    }
}

# =============================================================================
# 1. Function definition  —  FAILS until Invoke-ConfigApi is added
# =============================================================================

Describe 'configure.ps1 - Invoke-ConfigApi function definition' {

    It 'should define an Invoke-ConfigApi function' {
        $script:Content | Should -Match 'function Invoke-ConfigApi\b' `
            -Because 'Invoke-ConfigApi must be defined in configure.ps1 as the foundation for API call wrappers'
    }
}

# =============================================================================
# 2. Return object structure  —  FAILS until implementation exists
# =============================================================================

Describe 'configure.ps1 - Invoke-ConfigApi return object property contract' {

    BeforeAll {
        $fnPattern           = 'function Invoke-ConfigApi[\s\S]*?\n}'
        $fnMatch             = [regex]::Match($script:Content, $fnPattern)
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should return an object with a Success property' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'Success\s*=' `
            -Because 'The return object must include a Success boolean so callers can branch on success/failure without inspecting HTTP status codes directly'
    }

    It 'should return an object with a StatusCode property' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'StatusCode\s*=' `
            -Because 'The return object must expose the raw HTTP status code so callers can log or inspect it when needed'
    }

    It 'should return an object with a Body property' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'Body\s*=' `
            -Because 'The return object must expose the parsed response body so callers can access response data without re-parsing'
    }

    It 'should return an object with an AlreadyExists property' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'AlreadyExists\s*=' `
            -Because 'The AlreadyExists flag distinguishes 409 Conflict (benign duplicate) from hard failures so callers can treat it as info rather than an error'
    }
}

# =============================================================================
# 3. Internal structure — wraps Invoke-RestMethod with error handling
# =============================================================================

Describe 'configure.ps1 - Invoke-ConfigApi internal implementation structure' {

    BeforeAll {
        $fnPattern           = 'function Invoke-ConfigApi[\s\S]*?\n}'
        $fnMatch             = [regex]::Match($script:Content, $fnPattern)
        $script:FunctionBody = if ($fnMatch.Success) { $fnMatch.Value } else { $null }
    }

    It 'should call Invoke-RestMethod internally' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match 'Invoke-RestMethod' `
            -Because 'Invoke-ConfigApi is a wrapper around Invoke-RestMethod; it must delegate the actual HTTP call to that cmdlet'
    }

    It 'should contain a try/catch block for exception handling' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        ($script:FunctionBody -match '\btry\b') -and ($script:FunctionBody -match '\bcatch\b') | Should -Be $true `
            -Because 'Invoke-RestMethod throws on HTTP errors; Invoke-ConfigApi must catch these to translate them into structured return objects rather than letting exceptions propagate'
    }

    It 'should check for status code 409 and set AlreadyExists' {
        if ($null -eq $script:FunctionBody) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $script:FunctionBody | Should -Match '409' `
            -Because '409 Conflict is the sentinel value for "resource already exists"; the function must treat it distinctly from other 4xx errors'
    }
}

# =============================================================================
# 4. Behavioral: 201 Created — success path
# =============================================================================

Describe 'Invoke-ConfigApi - 201 Created response returns success result' {

    BeforeAll {
        if (-not $script:FunctionLoaded) { return }
        Mock Write-Warning { }
        Mock Write-WarningMessage { }
        Mock Write-Info { }
        Mock Invoke-RestMethod {
            return [PSCustomObject]@{ id = 42; name = 'Radarr' }
        }
    }

    It 'should return Success = $true for a 201 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $result.Success | Should -Be $true `
            -Because 'A 201 Created response means the resource was successfully created; Success must be $true'
    }

    It 'should return AlreadyExists = $false for a 201 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $result.AlreadyExists | Should -Be $false `
            -Because 'A 201 Created confirms the resource is new; AlreadyExists must be $false'
    }

    It 'should not emit a Write-Warning for a 201 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        Should -Invoke Write-Warning -Times 0 -Scope It `
            -Because 'Success responses must not produce warnings; warnings are reserved for failures'
        Should -Invoke Write-WarningMessage -Times 0 -Scope It `
            -Because 'Success responses must not produce warnings; warnings are reserved for failures'
    }
}

# =============================================================================
# 5. Behavioral: 200 OK — success path
# =============================================================================

Describe 'Invoke-ConfigApi - 200 OK response returns success result' {

    BeforeAll {
        if (-not $script:FunctionLoaded) { return }
        Mock Write-Warning { }
        Mock Write-WarningMessage { }
        Mock Write-Info { }
        Mock Invoke-RestMethod {
            return [PSCustomObject]@{ id = 7; status = 'active' }
        }
    }

    It 'should return Success = $true for a 200 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://sonarr.local/api/v3/rootfolder' -Method 'Post'
        $result.Success | Should -Be $true `
            -Because 'A 200 OK response is a successful outcome; Success must be $true'
    }

    It 'should return AlreadyExists = $false for a 200 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://sonarr.local/api/v3/rootfolder' -Method 'Post'
        $result.AlreadyExists | Should -Be $false `
            -Because '200 OK is not a conflict response; AlreadyExists must be $false'
    }
}

# =============================================================================
# 6. Behavioral: 409 Conflict — AlreadyExists flag, no warning emitted
# =============================================================================

Describe 'Invoke-ConfigApi - 409 Conflict response sets AlreadyExists flag' {

    BeforeAll {
        if (-not $script:FunctionLoaded) { return }
        Mock Write-Warning { }
        Mock Write-WarningMessage { }
        Mock Write-Info { }
        Mock Invoke-RestMethod {
            $errRecord = New-MockHttpErrorRecord -StatusCode 409 -Body '{"message":"Already exists"}'
            $PSCmdlet.ThrowTerminatingError($errRecord)
        }
    }

    It 'should return AlreadyExists = $true for a 409 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $result.AlreadyExists | Should -Be $true `
            -Because '409 Conflict means the resource already exists; AlreadyExists must be set so callers treat this as benign rather than a hard failure'
    }

    It 'should return Success = $true for a 409 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $result.Success | Should -Be $true `
            -Because '409 is an expected idempotency outcome (resource already configured); the overall configuration attempt did not fail — Success=$true with AlreadyExists=$true signals "nothing to do"'
    }

    It 'should return StatusCode = 409' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $result.StatusCode | Should -Be 409 `
            -Because 'The raw HTTP status code must be preserved in the return object for logging and debugging purposes'
    }

    It 'should NOT emit a Write-Warning for a 409 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        Should -Invoke Write-Warning -Times 0 -Scope It `
            -Because '409 is a benign info-level outcome; emitting a warning would cause false alarm noise in the configuration output'
        Should -Invoke Write-WarningMessage -Times 0 -Scope It `
            -Because '409 is a benign info-level outcome; it must be logged at info/verbose level, never warning level'
    }
}

# =============================================================================
# 7. Behavioral: 400 Bad Request — failure, warning with status code and body
# =============================================================================

Describe 'Invoke-ConfigApi - 400 Bad Request response surfaces failure with warning' {

    BeforeAll {
        if (-not $script:FunctionLoaded) { return }
        $script:WarningMessages = [System.Collections.Generic.List[string]]::new()
        Mock Write-Warning   { $script:WarningMessages.Add($Message) }
        Mock Write-WarningMessage { $script:WarningMessages.Add($Message) }
        Mock Write-Info { }
        Mock Invoke-RestMethod {
            $errRecord = New-MockHttpErrorRecord -StatusCode 400 -Body '{"message":"Invalid configuration: missing required field"}'
            $PSCmdlet.ThrowTerminatingError($errRecord)
        }
    }

    BeforeEach {
        $script:WarningMessages.Clear()
    }

    It 'should return Success = $false for a 400 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $result.Success | Should -Be $false `
            -Because 'A 400 Bad Request is a caller error; the API call failed and Success must be $false'
    }

    It 'should return StatusCode = 400' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $result.StatusCode | Should -Be 400 `
            -Because 'The status code must be preserved so callers and log consumers can identify the error class'
    }

    It 'should emit at least one warning for a 400 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $script:WarningMessages.Count | Should -BeGreaterThan 0 `
            -Because '400 errors indicate a configuration bug; operators must see a warning so they can diagnose and fix the problem'
    }

    It 'should include "400" in the warning message' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $allWarnings = $script:WarningMessages -join ' '
        $allWarnings | Should -Match '400' `
            -Because 'The HTTP status code must appear in the warning so operators immediately know what class of error occurred without having to consult logs'
    }

    It 'should include the response body in the warning message' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://radarr.local/api/v3/downloadclient' -Method 'Post'
        $allWarnings = $script:WarningMessages -join ' '
        $allWarnings | Should -Match 'Invalid configuration|missing required field' `
            -Because 'The API error message in the response body must be surfaced in the warning so operators can diagnose the root cause without inspecting raw HTTP traffic'
    }
}

# =============================================================================
# 8. Behavioral: 500 Internal Server Error — failure, warning with status and body
# =============================================================================

Describe 'Invoke-ConfigApi - 500 Internal Server Error response surfaces failure with warning' {

    BeforeAll {
        if (-not $script:FunctionLoaded) { return }
        $script:WarningMessages500 = [System.Collections.Generic.List[string]]::new()
        Mock Write-Warning        { $script:WarningMessages500.Add($Message) }
        Mock Write-WarningMessage { $script:WarningMessages500.Add($Message) }
        Mock Write-Info { }
        Mock Invoke-RestMethod {
            $errRecord = New-MockHttpErrorRecord -StatusCode 500 -Body '{"message":"Internal server error: database connection failed"}'
            $PSCmdlet.ThrowTerminatingError($errRecord)
        }
    }

    BeforeEach {
        $script:WarningMessages500.Clear()
    }

    It 'should return Success = $false for a 500 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://sonarr.local/api/v3/downloadclient' -Method 'Post'
        $result.Success | Should -Be $false `
            -Because 'A 500 Internal Server Error means the service is broken; Success must be $false'
    }

    It 'should return StatusCode = 500' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://sonarr.local/api/v3/downloadclient' -Method 'Post'
        $result.StatusCode | Should -Be 500 `
            -Because 'The 500 status code must be surfaced so operators can distinguish service-side failures from request failures'
    }

    It 'should emit at least one warning for a 500 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://sonarr.local/api/v3/downloadclient' -Method 'Post'
        $script:WarningMessages500.Count | Should -BeGreaterThan 0 `
            -Because 'Server errors must produce visible warnings so operators know configuration did not fully succeed'
    }

    It 'should include "500" in the warning message' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://sonarr.local/api/v3/downloadclient' -Method 'Post'
        $allWarnings = $script:WarningMessages500 -join ' '
        $allWarnings | Should -Match '500' `
            -Because 'The HTTP status code must appear in the warning so operators can triage whether this is a transient server error (5xx) or a client error (4xx)'
    }

    It 'should include the response body in the warning message' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://sonarr.local/api/v3/downloadclient' -Method 'Post'
        $allWarnings = $script:WarningMessages500 -join ' '
        $allWarnings | Should -Match 'database connection failed|Internal server error' `
            -Because 'The server error body must appear in the warning to give operators actionable diagnostic detail'
    }

    It 'should return AlreadyExists = $false for a 500 response' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://sonarr.local/api/v3/downloadclient' -Method 'Post'
        $result.AlreadyExists | Should -Be $false `
            -Because 'A 500 is not a conflict; AlreadyExists must be $false to prevent callers from silently ignoring the error'
    }
}

# =============================================================================
# 9. Behavioral: Network timeout — failure, warning emitted
# =============================================================================

Describe 'Invoke-ConfigApi - network timeout results in failure with warning' {

    BeforeAll {
        if (-not $script:FunctionLoaded) { return }
        $script:TimeoutWarnings = [System.Collections.Generic.List[string]]::new()
        Mock Write-Warning        { $script:TimeoutWarnings.Add($Message) }
        Mock Write-WarningMessage { $script:TimeoutWarnings.Add($Message) }
        Mock Write-Info { }
        Mock Invoke-RestMethod {
            $errRecord = New-MockTimeoutErrorRecord
            $PSCmdlet.ThrowTerminatingError($errRecord)
        }
    }

    BeforeEach {
        $script:TimeoutWarnings.Clear()
    }

    It 'should return Success = $false for a network timeout' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://prowlarr.local/api/v1/indexer' -Method 'Post'
        $result.Success | Should -Be $false `
            -Because 'A network timeout means the API call could not complete; Success must be $false'
    }

    It 'should emit at least one warning for a timeout' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $null = Invoke-ConfigApi -Uri 'http://prowlarr.local/api/v1/indexer' -Method 'Post'
        $script:TimeoutWarnings.Count | Should -BeGreaterThan 0 `
            -Because 'A timeout leaves the system in an unknown state; operators must be warned so they can retry or investigate'
    }

    It 'should return AlreadyExists = $false for a timeout' {
        if (-not $script:FunctionLoaded) {
            Set-ItResult -Skipped -Because 'Invoke-ConfigApi is not yet defined'
            return
        }
        $result = Invoke-ConfigApi -Uri 'http://prowlarr.local/api/v1/indexer' -Method 'Post'
        $result.AlreadyExists | Should -Be $false `
            -Because 'A timeout provides no information about whether the resource exists; AlreadyExists must default to $false'
    }
}

# =============================================================================
# 10. PSScriptAnalyzer compliance — must pass before and after implementation
# =============================================================================

Describe 'configure.ps1 - PSScriptAnalyzer clean after adding Invoke-ConfigApi' {

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

    It 'should produce zero PSScriptAnalyzer warnings or errors' {
        $report = $script:AnalyzerFindings | ForEach-Object {
            "[$($_.Severity)] $($_.RuleName) at line $($_.Line): $($_.Message)"
        }
        $script:AnalyzerFindings | Should -BeNullOrEmpty `
            -Because ("Invoke-ConfigApi must not introduce PSScriptAnalyzer issues. Found $($script:AnalyzerFindings.Count) issue(s):`n" + ($report -join "`n"))
    }

    It 'should have no PSUseDeclaredVarsMoreThanAssignments violations' {
        $violations = $script:AnalyzerFindings |
            Where-Object { $_.RuleName -eq 'PSUseDeclaredVarsMoreThanAssignments' }
        $violations | Should -BeNullOrEmpty `
            -Because 'All variables declared inside Invoke-ConfigApi must be used; unused variables indicate dead code or a missing return path'
    }

    It 'should parse as valid PowerShell syntax' {
        $parseErrors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize($script:Content, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty `
            -Because 'configure.ps1 must remain syntactically valid after adding Invoke-ConfigApi'
    }
}
