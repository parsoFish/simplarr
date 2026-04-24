@{
    # PSScriptAnalyzer configuration for simplarr CI.
    #
    # We run Warning + Error severity (see .github/workflows/ci.yml).
    # The rules excluded below are intentionally disabled because they
    # either don't fit the project's style (BOM on UTF-8) or flag
    # deliberate patterns in test helpers (empty catch for env-dependent
    # module loads, Invoke-Expression for AST testing, reserved
    # parameter signatures for interface contracts).
    Severity   = @('Warning', 'Error')

    ExcludeRules = @(
        # UTF-8 BOM is unnecessary on non-Windows platforms and the
        # project's Pester test files intentionally ship as UTF-8 without
        # BOM to work cleanly on Linux/macOS CI runners.
        'PSUseBOMForUnicodeEncodedFile',

        # PowerShell parameters kept for call-signature compatibility or
        # reserved for future use fire this rule even when the intent
        # is deliberate. The codebase uses this pattern in setup/config
        # helpers where port parameters accept all known services.
        'PSReviewUnusedParameter',

        # Test-InvokeConfigApi.Tests.ps1 uses Invoke-Expression to
        # execute an extracted AST fragment under test. This is the
        # exact use case Invoke-Expression exists for; avoiding it would
        # require reimplementing an AST evaluator.
        'PSAvoidUsingInvokeExpression',

        # Test-IndexerDefinitions.Tests.ps1 intentionally swallows module-
        # load errors that occur when test env vars aren't set; the
        # failure mode is "skip this test", not "propagate the error."
        'PSAvoidUsingEmptyCatchBlock'
    )
}
