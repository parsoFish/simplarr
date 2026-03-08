#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# =============================================================================
# Homepage Config Injection Tests (Pester)
# =============================================================================
# Validates that config.json injection is properly implemented in the homepage:
#
#   Structural:
#     - homepage/config.json.template exists with all required port placeholders
#     - homepage/Dockerfile references an entrypoint script
#     - The entrypoint script uses envsubst to render config.json at startup
#     - dashboard.js fetches /config.json and falls back to hardcoded defaults
#     - status.js fetches /config.json and falls back to hardcoded defaults
#     - Fallback defaults in JS match the current canonical port values
#     - docker-compose-unified.yml passes port env vars to the homepage service
#     - docker-compose-pi.yml passes port env vars to the homepage service
#
# Work item: Add config.json injection to homepage for dynamic port configuration
#
# Acceptance criteria tested here:
#   1. homepage/config.json.template exists with ${SERVICE_PORT} placeholders for
#      every service (plex, overseerr, radarr, sonarr, prowlarr, qbittorrent, tautulli)
#   2. homepage/Dockerfile references an entrypoint shell script
#   3. The entrypoint script calls envsubst, reads config.json.template, and writes
#      config.json; then starts nginx
#   4. dashboard.js fetches /config.json, reads port values from the response, and
#      has a catch block that falls back to hardcoded defaults
#   5. status.js fetches /config.json, reads port values from the response, and
#      has a catch block that falls back to hardcoded defaults
#   6. Fallback port values in both JS files match canonical values
#      (plex=32400, overseerr=5055, radarr=7878, sonarr=8989,
#       prowlarr=9696, qbittorrent=8080, tautulli=8181)
#   7. docker-compose-unified.yml and docker-compose-pi.yml pass all seven
#      port env vars to the homepage service
#
# TDD: These tests are written BEFORE the implementation exists and MUST fail
# on the current codebase until the full implementation is complete.
#
# Usage (from repo root or dev-testing/):
#   Invoke-Pester ./dev-testing/Test-HomepageConfigInjection.Tests.ps1 -Output Detailed
#
# Prerequisites:
#   Install-Module Pester -MinimumVersion 5.0 -Force
# =============================================================================

BeforeAll {
    $script:RepoRoot        = Split-Path -Parent $PSScriptRoot
    $script:HomepageDir     = Join-Path $script:RepoRoot 'homepage'
    $script:ConfigTemplate  = Join-Path $script:HomepageDir 'config.json.template'
    $script:Dockerfile      = Join-Path $script:HomepageDir 'Dockerfile'
    $script:DashboardJs     = Join-Path $script:HomepageDir 'js' 'dashboard.js'
    $script:StatusJs        = Join-Path $script:HomepageDir 'js' 'status.js'
    $script:ComposeUnified  = Join-Path $script:RepoRoot 'docker-compose-unified.yml'
    $script:ComposePi       = Join-Path $script:RepoRoot 'docker-compose-pi.yml'

    # Cache file contents as raw strings (null when missing)
    $script:TemplateContent   = if (Test-Path $script:ConfigTemplate)  { Get-Content -Raw $script:ConfigTemplate }  else { $null }
    $script:DockerfileContent = if (Test-Path $script:Dockerfile)       { Get-Content -Raw $script:Dockerfile }       else { $null }
    $script:DashboardContent  = if (Test-Path $script:DashboardJs)      { Get-Content -Raw $script:DashboardJs }      else { $null }
    $script:StatusContent     = if (Test-Path $script:StatusJs)         { Get-Content -Raw $script:StatusJs }         else { $null }
    $script:UnifiedContent    = if (Test-Path $script:ComposeUnified)   { Get-Content -Raw $script:ComposeUnified }   else { $null }
    $script:PiContent         = if (Test-Path $script:ComposePi)        { Get-Content -Raw $script:ComposePi }        else { $null }

    # Required placeholder names and their canonical default port values
    $script:ServicePorts = [ordered]@{
        PLEX_PORT        = 32400
        OVERSEERR_PORT   = 5055
        RADARR_PORT      = 7878
        SONARR_PORT      = 8989
        PROWLARR_PORT    = 9696
        QBITTORRENT_PORT = 8080
        TAUTULLI_PORT    = 8181
    }

    # Locate the entrypoint script referenced in the Dockerfile
    $script:EntrypointScript = $null
    if ($null -ne $script:DockerfileContent) {
        # Try to extract script name from COPY directives
        $copyMatch = [regex]::Match($script:DockerfileContent, 'COPY\s+(\S+\.sh)')
        if ($copyMatch.Success) {
            $scriptName = $copyMatch.Groups[1].Value
            $candidate  = Join-Path $script:HomepageDir $scriptName
            if (Test-Path $candidate) {
                $script:EntrypointScript = $candidate
            }
        }
        # Fall back to well-known names if COPY extraction failed
        if ($null -eq $script:EntrypointScript) {
            foreach ($name in @('entrypoint.sh', 'docker-entrypoint.sh', 'start.sh')) {
                $candidate = Join-Path $script:HomepageDir $name
                if (Test-Path $candidate) {
                    $script:EntrypointScript = $candidate
                    break
                }
            }
        }
    }

    $script:EntrypointContent = if ($null -ne $script:EntrypointScript -and (Test-Path $script:EntrypointScript)) {
        Get-Content -Raw $script:EntrypointScript
    } else {
        $null
    }
}

# =============================================================================
# Section 1 — config.json.template
# =============================================================================

Describe 'homepage/config.json.template — existence' {

    It 'should exist at homepage/config.json.template' {
        $script:ConfigTemplate | Should -Exist `
            -Because 'The template file is the source for envsubst to generate config.json at container startup'
    }

    It 'should not be empty' {
        $script:TemplateContent | Should -Not -BeNullOrEmpty `
            -Because 'The template must contain JSON structure with service port placeholders'
    }
}

Describe 'homepage/config.json.template — required port placeholders' {

    foreach ($var in $script:ServicePorts.Keys) {
        It "should contain the `${$var} placeholder" {
            if ($null -eq $script:TemplateContent) {
                Set-ItResult -Skipped -Because 'config.json.template does not exist yet'
                return
            }
            $script:TemplateContent | Should -Match ([regex]::Escape('${' + $var + '}')) `
                -Because "The template must substitute ${var} with the runtime environment variable value"
        }
    }

    It 'should contain JSON keys for all services (plex, radarr, sonarr)' {
        if ($null -eq $script:TemplateContent) {
            Set-ItResult -Skipped -Because 'config.json.template does not exist yet'
            return
        }
        $script:TemplateContent | Should -Match '"plex"'    -Because 'Template must have a plex key'
        $script:TemplateContent | Should -Match '"radarr"'  -Because 'Template must have a radarr key'
        $script:TemplateContent | Should -Match '"sonarr"'  -Because 'Template must have a sonarr key'
    }
}

# =============================================================================
# Section 2 — Dockerfile entrypoint
# =============================================================================

Describe 'homepage/Dockerfile — entrypoint script reference' {

    It 'should exist at homepage/Dockerfile' {
        $script:Dockerfile | Should -Exist `
            -Because 'The homepage Dockerfile must be updated to use an entrypoint script'
    }

    It 'should reference an entrypoint or CMD shell script' {
        if ($null -eq $script:DockerfileContent) {
            Set-ItResult -Skipped -Because 'homepage/Dockerfile does not exist'
            return
        }
        $script:DockerfileContent | Should -Match 'ENTRYPOINT|entrypoint|CMD.*\.sh|COPY.*\.sh' `
            -Because 'The Dockerfile must COPY and invoke an entrypoint script that runs envsubst before nginx'
    }
}

Describe 'homepage entrypoint script — envsubst and nginx' {

    It 'should have an entrypoint shell script in homepage/' {
        $script:EntrypointScript | Should -Not -BeNullOrEmpty `
            -Because 'An entrypoint script (e.g. entrypoint.sh) must exist to substitute env vars into config.json'
    }

    It 'should call envsubst to substitute environment variables' {
        if ($null -eq $script:EntrypointContent) {
            Set-ItResult -Skipped -Because 'No entrypoint script found in homepage/'
            return
        }
        $script:EntrypointContent | Should -Match 'envsubst' `
            -Because 'envsubst is the tool that renders config.json.template into config.json at startup'
    }

    It 'should reference config.json.template as the envsubst input' {
        if ($null -eq $script:EntrypointContent) {
            Set-ItResult -Skipped -Because 'No entrypoint script found in homepage/'
            return
        }
        $script:EntrypointContent | Should -Match 'config\.json\.template' `
            -Because 'The entrypoint must read the template file as the envsubst input'
    }

    It 'should write output to config.json' {
        if ($null -eq $script:EntrypointContent) {
            Set-ItResult -Skipped -Because 'No entrypoint script found in homepage/'
            return
        }
        $script:EntrypointContent | Should -Match 'config\.json' `
            -Because 'The entrypoint must write the rendered template to config.json in the nginx serve root'
    }

    It 'should hand off to nginx after rendering config' {
        if ($null -eq $script:EntrypointContent) {
            Set-ItResult -Skipped -Because 'No entrypoint script found in homepage/'
            return
        }
        $script:EntrypointContent | Should -Match 'nginx|exec' `
            -Because 'The entrypoint must start nginx (e.g. exec nginx -g "daemon off;") after rendering config.json'
    }
}

# =============================================================================
# Section 3 — dashboard.js config fetch and fallback
# =============================================================================

Describe 'homepage/js/dashboard.js — fetches /config.json' {

    It 'should exist at homepage/js/dashboard.js' {
        $script:DashboardJs | Should -Exist `
            -Because 'dashboard.js must exist and be updated to fetch port config dynamically'
    }

    It 'should fetch /config.json to read port configuration' {
        if ($null -eq $script:DashboardContent) {
            Set-ItResult -Skipped -Because 'dashboard.js does not exist'
            return
        }
        $script:DashboardContent | Should -Match "fetch.*config\.json" `
            -Because 'dashboard.js must call fetch("/config.json") (or equivalent) to retrieve injected ports'
    }

    It 'should have a catch block for config.json fetch failures' {
        if ($null -eq $script:DashboardContent) {
            Set-ItResult -Skipped -Because 'dashboard.js does not exist'
            return
        }
        $script:DashboardContent | Should -Match '\.catch\b|catch\s*\(' `
            -Because 'fetch failures must be caught and handled with fallback defaults so the page still works'
    }

    It 'should read port values from the fetched config object' {
        if ($null -eq $script:DashboardContent) {
            Set-ItResult -Skipped -Because 'dashboard.js does not exist'
            return
        }
        $script:DashboardContent | Should -Match 'config\[|config\.' `
            -Because 'dashboard.js must read service ports from the parsed config.json response'
    }
}

Describe 'homepage/js/dashboard.js — fallback defaults match canonical ports' {

    foreach ($entry in $script:ServicePorts.GetEnumerator()) {
        $service = $entry.Key -replace '_PORT', '' -ToLower
        $port    = $entry.Value
        It "should contain fallback port $port for $service" {
            if ($null -eq $script:DashboardContent) {
                Set-ItResult -Skipped -Because 'dashboard.js does not exist'
                return
            }
            $script:DashboardContent | Should -Match $port `
                -Because "The fallback default for $service must be $port to match the current canonical value"
        }
    }

    It 'should not have a bare top-level hardcoded services object without a fallback guard' {
        if ($null -eq $script:DashboardContent) {
            Set-ItResult -Skipped -Because 'dashboard.js does not exist'
            return
        }
        # If a const services = { ... } pattern is present it must be inside a catch/fallback
        if ($script:DashboardContent -match 'const services\s*=\s*\{') {
            $script:DashboardContent | Should -Match 'catch|fallback|defaults' `
                -Because 'Hardcoded port values must only appear inside the catch/fallback block, not at the top level'
        } else {
            # No bare services object — ports come from config.json (preferred pattern)
            $true | Should -Be $true
        }
    }
}

# =============================================================================
# Section 4 — status.js config fetch and fallback
# =============================================================================

Describe 'homepage/js/status.js — fetches /config.json' {

    It 'should exist at homepage/js/status.js' {
        $script:StatusJs | Should -Exist `
            -Because 'status.js must exist and be updated to fetch health-check URL ports dynamically'
    }

    It 'should fetch /config.json to read health-check URL ports' {
        if ($null -eq $script:StatusContent) {
            Set-ItResult -Skipped -Because 'status.js does not exist'
            return
        }
        $script:StatusContent | Should -Match "fetch.*config\.json" `
            -Because 'status.js must call fetch("/config.json") to retrieve injected ports for health-check URLs'
    }

    It 'should have a catch block for config.json fetch failures' {
        if ($null -eq $script:StatusContent) {
            Set-ItResult -Skipped -Because 'status.js does not exist'
            return
        }
        $script:StatusContent | Should -Match '\.catch\b|catch\s*\(' `
            -Because 'fetch failures must be caught and handled with fallback defaults so health checks still run'
    }

    It 'should still define checkAll/checkService health-check functions (no regression)' {
        if ($null -eq $script:StatusContent) {
            Set-ItResult -Skipped -Because 'status.js does not exist'
            return
        }
        $script:StatusContent | Should -Match 'checkAll|checkService' `
            -Because 'The health-check functions must remain defined — removing them would be a behavioral regression'
    }

    It 'should read port values from the fetched config object' {
        if ($null -eq $script:StatusContent) {
            Set-ItResult -Skipped -Because 'status.js does not exist'
            return
        }
        $script:StatusContent | Should -Match 'config\[|config\.' `
            -Because 'status.js must read service ports from the parsed config.json response'
    }
}

Describe 'homepage/js/status.js — fallback defaults match canonical ports' {

    foreach ($entry in $script:ServicePorts.GetEnumerator()) {
        $service = $entry.Key -replace '_PORT', '' -ToLower
        $port    = $entry.Value
        It "should contain fallback port $port for $service" {
            if ($null -eq $script:StatusContent) {
                Set-ItResult -Skipped -Because 'status.js does not exist'
                return
            }
            $script:StatusContent | Should -Match $port `
                -Because "The fallback default for $service must be $port to match the current canonical value"
        }
    }
}

# =============================================================================
# Section 5 — docker-compose-unified.yml homepage env vars
# =============================================================================

Describe 'docker-compose-unified.yml — homepage service passes port env vars' {

    It 'should exist at docker-compose-unified.yml' {
        $script:ComposeUnified | Should -Exist `
            -Because 'docker-compose-unified.yml must be updated to pass port env vars to the homepage service'
    }

    foreach ($var in $script:ServicePorts.Keys) {
        It "should pass $var env var to the homepage service" {
            if ($null -eq $script:UnifiedContent) {
                Set-ItResult -Skipped -Because 'docker-compose-unified.yml does not exist'
                return
            }
            $script:UnifiedContent | Should -Match $var `
                -Because "The homepage container needs $var so envsubst can inject the correct port into config.json"
        }
    }
}

# =============================================================================
# Section 6 — docker-compose-pi.yml homepage env vars
# =============================================================================

Describe 'docker-compose-pi.yml — homepage service passes port env vars' {

    It 'should exist at docker-compose-pi.yml' {
        $script:ComposePi | Should -Exist `
            -Because 'docker-compose-pi.yml must be updated to pass port env vars to the homepage service'
    }

    foreach ($var in $script:ServicePorts.Keys) {
        It "should pass $var env var to the homepage service" {
            if ($null -eq $script:PiContent) {
                Set-ItResult -Skipped -Because 'docker-compose-pi.yml does not exist'
                return
            }
            $script:PiContent | Should -Match $var `
                -Because "The homepage container needs $var so envsubst can inject the correct port into config.json"
        }
    }
}
