#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Resolve-ConfigDir .env Autoload Tests (Pester)
# =============================================================================
# Issue #29, round 2: setup.ps1 writes DOCKER_CONFIG into .env and docker
# compose reads it automatically, but configure.ps1 never did — running it per
# the readme silently fell back to .\configs. Resolve-ConfigDir must auto-load
# DOCKER_CONFIG from the .env next to the script, with precedence:
#   -ConfigDir param > $env:DOCKER_CONFIG > .env DOCKER_CONFIG= > .\configs
#
# Mirrors dev-testing/test_issue_28_29_regressions.sh Phase 3b (bash parity).
#
# Usage:
#   Invoke-Pester ./dev-testing/Test-ResolveConfigDir.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent $PSScriptRoot
    $script:ConfigurePath = Join-Path $script:RepoRoot 'configure.ps1'
    $script:Content       = Get-Content -Raw $script:ConfigurePath

    $tokens = $null
    $errors = $null
    $ast    = [System.Management.Automation.Language.Parser]::ParseInput(
        $script:Content, [ref]$tokens, [ref]$errors
    )

    $helperNames = @('Write-Info', 'Resolve-ConfigDir')

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

    # Sandbox directory acting as the "script root" holding .env
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "resolve-configdir-tests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Sandbox | Out-Null

    # Preserve any pre-existing DOCKER_CONFIG so tests are hermetic
    $script:SavedDockerConfig = $env:DOCKER_CONFIG
}

AfterAll {
    if (Test-Path $script:Sandbox) {
        Remove-Item -Recurse -Force $script:Sandbox
    }
    $env:DOCKER_CONFIG = $script:SavedDockerConfig
}

Describe 'Resolve-ConfigDir' {

    BeforeEach {
        $env:DOCKER_CONFIG = $null
        Get-ChildItem $script:Sandbox | Remove-Item -Recurse -Force
    }

    It 'is defined in configure.ps1' {
        Get-Command Resolve-ConfigDir -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'loads DOCKER_CONFIG from .env when no env vars are set' {
        $expected = Join-Path $script:Sandbox 'from-env-file'
        Set-Content -Path (Join-Path $script:Sandbox '.env') -Value "PUID=1000`nDOCKER_CONFIG=$expected"
        Resolve-ConfigDir -ConfigDir '.\configs' -ScriptRoot $script:Sandbox | Should -Be $expected
    }

    It 'lets $env:DOCKER_CONFIG override .env' {
        Set-Content -Path (Join-Path $script:Sandbox '.env') -Value 'DOCKER_CONFIG=/from/env/file'
        $env:DOCKER_CONFIG = '/from/shell'
        Resolve-ConfigDir -ConfigDir '.\configs' -ScriptRoot $script:Sandbox | Should -Be '/from/shell'
    }

    It 'lets an explicit -ConfigDir outrank $env:DOCKER_CONFIG and .env' {
        Set-Content -Path (Join-Path $script:Sandbox '.env') -Value 'DOCKER_CONFIG=/from/env/file'
        $env:DOCKER_CONFIG = '/from/shell'
        Resolve-ConfigDir -ConfigDir '/explicit/param' -ScriptRoot $script:Sandbox | Should -Be '/explicit/param'
    }

    It 'falls back to .\configs when no .env and no env vars exist' {
        Resolve-ConfigDir -ConfigDir '.\configs' -ScriptRoot $script:Sandbox | Should -Be '.\configs'
    }

    It 'prefers the last DOCKER_CONFIG line and strips quotes' {
        $expected = Join-Path $script:Sandbox 'second-real'
        Set-Content -Path (Join-Path $script:Sandbox '.env') -Value "DOCKER_CONFIG=/first/stale`nDOCKER_CONFIG=`"$expected`""
        Resolve-ConfigDir -ConfigDir '.\configs' -ScriptRoot $script:Sandbox | Should -Be $expected
    }

    It 'resolves a relative DOCKER_CONFIG against the script root' {
        Set-Content -Path (Join-Path $script:Sandbox '.env') -Value 'DOCKER_CONFIG=./docker'
        Resolve-ConfigDir -ConfigDir '.\configs' -ScriptRoot $script:Sandbox |
            Should -Be (Join-Path $script:Sandbox 'docker')
    }

    It 'ignores an empty DOCKER_CONFIG= line and falls back to .\configs' {
        Set-Content -Path (Join-Path $script:Sandbox '.env') -Value 'DOCKER_CONFIG='
        Resolve-ConfigDir -ConfigDir '.\configs' -ScriptRoot $script:Sandbox | Should -Be '.\configs'
    }

    It 'is called from the main flow of configure.ps1' {
        $script:Content | Should -Match '\$ConfigDir\s*=\s*Resolve-ConfigDir\s+-ConfigDir\s+\$ConfigDir'
    }
}
