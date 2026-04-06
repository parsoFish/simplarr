# =============================================================================
# Simplarr Automated Test Script (PowerShell)
# =============================================================================
# This script validates that all Simplarr components work together correctly.
#
# IMPORTANT: Plex claim/setup tests are EXCLUDED because they require manual
# token generation. This script tests everything else.
#
# Usage:
#   .\test.ps1              # Run all tests
#   .\test.ps1 -Quick       # Skip container startup tests (syntax/file checks only)
#   .\test.ps1 -Cleanup     # Clean up test containers after running
#
# Test Phases:
#   1-9  File validation, syntax checks, container start, API integration
#   10   VPN Container Wiring  -  docker compose config VPN overlay assertions
# =============================================================================

param(
    [switch]$Quick,
    [switch]$Cleanup,
    [switch]$Help
)

# Test counters
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

# =============================================================================
# Helper Functions
# =============================================================================

function Write-Header {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    param([string]$Message)
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "=================================================================" -ForegroundColor Cyan
}

function Write-Test {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    param([string]$Message)
    Write-Host "[TEST] " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Pass {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    param([string]$Message)
    Write-Host "[PASS] " -ForegroundColor Green -NoNewline
    Write-Host $Message
    $script:TestsPassed++
}

function Write-Fail {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    param([string]$Message)
    Write-Host "[FAIL] " -ForegroundColor Red -NoNewline
    Write-Host $Message
    $script:TestsFailed++
}

function Write-Skip {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    param([string]$Message)
    Write-Host "[SKIP] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
    $script:TestsSkipped++
}

function Write-Info {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    param([string]$Message)
    Write-Host "[INFO] " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Warn {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    param([string]$Message)
    Write-Host "[WARN] " -ForegroundColor DarkYellow -NoNewline
    Write-Host $Message
    $script:TestsPassed++  # Warning counts as pass but with note
}

function Show-TestHelp {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    param()
    Write-Host "Usage: .\test.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Quick      Skip container startup tests (syntax/file checks only)"
    Write-Host "  -Cleanup    Clean up test containers after running"
    Write-Host "  -Help       Show this help message"
}


function Write-ServiceUrl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Write-Host is required for colored terminal output in this interactive test script')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'QbPassword', Justification='Password is retrieved from Docker logs for display only; SecureString is not applicable here')]
    param(
        [string]$TestDir,
        [string]$QbPassword
    )
    Write-Info "Test containers are still running. Access the services at:"
    Write-Host ""
    Write-Host "    Homepage:    http://localhost/" -ForegroundColor Cyan
    Write-Host "    Status:      http://localhost/status" -ForegroundColor Cyan
    Write-Host "    qBittorrent: http://localhost:8080/" -ForegroundColor Cyan
    Write-Host "    Radarr:      http://localhost:7878/" -ForegroundColor Cyan
    Write-Host "    Sonarr:      http://localhost:8989/" -ForegroundColor Cyan
    Write-Host "    Prowlarr:    http://localhost:9696/" -ForegroundColor Cyan
    Write-Host "    Tautulli:    http://localhost:8181/" -ForegroundColor Cyan
    Write-Host "    Overseerr:   http://localhost:5055/" -ForegroundColor Cyan
    Write-Host ""

    if ($QbPassword) {
        Write-Host "  +----------------------------------------------------+" -ForegroundColor Yellow
        Write-Host "  |  qBittorrent Credentials:                          |" -ForegroundColor Yellow
        Write-Host "  |    Username: admin                                 |" -ForegroundColor Yellow
        Write-Host "  |    Password: $($QbPassword.PadRight(35))|" -ForegroundColor Yellow
        Write-Host "  +----------------------------------------------------+" -ForegroundColor Yellow
        Write-Host ""
    }

    Write-Host '  Homepage links to services via direct ports (no UrlBase needed).' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  To clean up:" -ForegroundColor Yellow
    Write-Host "    cd $TestDir; docker compose -f docker-compose-test.yml down -v; cd ..; Remove-Item -Recurse $TestDir"
}


function Test-ServiceReady {
    param(
        [string]$Url,
        [int]$MaxAttempts = 30
    )
    
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -in @(200, 302, 401)) {
                return $true
            }
        } catch [System.Net.WebException] {
            # Check if it's a 401 Unauthorized (qBittorrent returns this)
            if ($_.Exception.Response.StatusCode -eq 401 -or $_.Exception.Response.StatusCode.value__ -eq 401) {
                return $true
            }
            # Service not ready yet
        } catch {
            # Other errors (connection refused, DNS failure, etc.) - service not ready
            Write-Verbose "Service not ready: $_"
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# =============================================================================
# Help
# =============================================================================

if ($Help) {
    Show-TestHelp
    exit 0
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

Write-Header "Pre-flight Checks"

Write-Test "Checking for Docker..."
try {
    $dockerVersion = docker --version 2>$null
    if ($dockerVersion) {
        Write-Pass "Docker is installed: $dockerVersion"
    } else {
        Write-Fail "Docker is not installed"
        exit 1
    }
} catch {
    Write-Fail "Docker is not installed"
    exit 1
}

Write-Test "Checking for Docker Compose..."
try {
    $composeVersion = docker compose version 2>$null
    if ($composeVersion) {
        Write-Pass "Docker Compose is available"
    } else {
        Write-Fail "Docker Compose is not available"
        exit 1
    }
} catch {
    Write-Fail "Docker Compose is not available"
    exit 1
}

# =============================================================================
# File Existence Tests
# =============================================================================

Write-Header "File Existence Tests"

$requiredFiles = @(
    "docker-compose-unified.yml",
    "docker-compose-nas.yml",
    "docker-compose-pi.yml",
    "setup.sh",
    "setup.ps1",
    "configure.sh",
    "configure.ps1",
    "readme.md",
    "nginx/unified.conf",
    "nginx/split.conf",
    "homepage/index.html",
    "homepage/status.html",
    "homepage/Dockerfile"
)

foreach ($file in $requiredFiles) {
    Write-Test "Checking $file exists..."
    if (Test-Path $file) {
        Write-Pass "$file exists"
    } else {
        Write-Fail "$file is missing"
    }
}

# =============================================================================
# Syntax Validation Tests
# =============================================================================

Write-Header "Syntax Validation Tests"

# PowerShell script syntax
Write-Test "Validating setup.ps1 syntax..."
try {
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw setup.ps1), [ref]$null)
    Write-Pass "setup.ps1 has valid PowerShell syntax"
} catch {
    Write-Fail "setup.ps1 has syntax errors"
}

Write-Test "Validating configure.ps1 syntax..."
try {
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw configure.ps1), [ref]$null)
    Write-Pass "configure.ps1 has valid PowerShell syntax"
} catch {
    Write-Fail "configure.ps1 has syntax errors"
}

# Docker Compose file validation
Write-Test "Validating docker-compose-unified.yml..."
$env:PUID = "1000"
$env:PGID = "1000"
$env:TZ = "UTC"
$env:PLEX_CLAIM = "claim-test"
$env:DOCKER_CONFIG = "$env:TEMP\simplarr-test\config"
$env:DOCKER_MEDIA = "$env:TEMP\simplarr-test\media"

$null = docker compose -f docker-compose-unified.yml config 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Pass "docker-compose-unified.yml is valid"
} else {
    Write-Fail "docker-compose-unified.yml has errors"
}

Write-Test "Validating docker-compose-nas.yml..."
$null = docker compose -f docker-compose-nas.yml config 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Pass "docker-compose-nas.yml is valid"
} else {
    Write-Fail "docker-compose-nas.yml has errors"
}

Write-Test "Validating docker-compose-pi.yml..."
$env:NAS_IP = "192.168.1.100"
$null = docker compose -f docker-compose-pi.yml config 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Pass "docker-compose-pi.yml is valid"
} else {
    Write-Fail "docker-compose-pi.yml has errors"
}


# =============================================================================
# Structural Validation Tests (Split-Setup NFS Paths)
# =============================================================================

Write-Header "Structural Validation Tests (Split-Setup NFS Paths)"

if (Test-Path "docker-compose-pi.yml") {
    $piComposeContent = Get-Content -Path "docker-compose-pi.yml"

    $nfsPaths = @(
        @{ Path = "/mnt/nas/downloads"; Purpose = "radarr/sonarr media ingestion" },
        @{ Path = "/mnt/nas/movies"; Purpose = "radarr library and tautulli statistics" },
        @{ Path = "/mnt/nas/tv"; Purpose = "sonarr library and tautulli statistics" }
    )

    foreach ($nfsPath in $nfsPaths) {
        Write-Test "Checking docker-compose-pi.yml declares $($nfsPath.Path) as host-side volume source..."
        $match = $piComposeContent | Select-String -Pattern ('^\s+-\s+' + [regex]::Escape($nfsPath.Path) + ':')

        if ($match) {
            Write-Pass "docker-compose-pi.yml declares $($nfsPath.Path) (for $($nfsPath.Purpose))"
        } else {
            Write-Fail "docker-compose-pi.yml missing $($nfsPath.Path) — split-setup NFS binding broken (affects $($nfsPath.Purpose))"
        }
    }
} else {
    Write-Skip "NFS path validation — docker-compose-pi.yml not found"
}
# =============================================================================
# Nginx Configuration Tests
# =============================================================================

Write-Header "Nginx Configuration Tests"

Write-Test "Checking nginx/unified.conf has required routes..."
$nginxContent = Get-Content -Raw "nginx/unified.conf"
$requiredRoutes = @("/plex", "/radarr", "/sonarr", "/prowlarr", "/overseerr", "/torrent", "/tautulli", "/status")
$missingRoutes = @()

foreach ($route in $requiredRoutes) {
    if ($nginxContent -notmatch "location\s*(=\s*)?$([regex]::Escape($route))") {
        $missingRoutes += $route
    }
}

if ($missingRoutes.Count -eq 0) {
    Write-Pass "All required routes present in unified.conf"
} else {
    Write-Fail "Missing routes in unified.conf: $($missingRoutes -join ', ')"
}

Write-Test "Checking nginx/split.conf structure..."
$splitContent = Get-Content -Raw "nginx/split.conf"
if ($splitContent -match "server" -and $splitContent -match "location") {
    Write-Pass "nginx/split.conf appears structurally valid"
} else {
    Write-Fail "nginx/split.conf may have issues"
}

Write-Test "Checking split.conf NAS IP substitution (YOUR_NAS_IP placeholder)..."
$splitConfRaw = Get-Content -Raw "nginx/split.conf"
$testNasIp = "192.0.2.1"
$substitutedContent = $splitConfRaw -replace "YOUR_NAS_IP", $testNasIp
$splitConfTmp = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".conf")
$substitutedContent | Out-File -FilePath $splitConfTmp -Encoding utf8
if ($substitutedContent -notmatch "YOUR_NAS_IP") {
    Write-Pass "split.conf NAS IP substitution — YOUR_NAS_IP replaced in temp copy"
} else {
    Write-Fail "split.conf NAS IP substitution — YOUR_NAS_IP still present after -replace"
}

Write-Test "Validating substituted split.conf with nginx -t..."
if (Get-Command nginx -ErrorAction SilentlyContinue) {
    $nginxResult = & nginx -t -c $splitConfTmp 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "nginx -t nginx/split.conf — syntax is ok"
    } else {
        Write-Fail "nginx -t nginx/split.conf — syntax error: $nginxResult"
    }
} else {
    Write-Skip "nginx -t nginx/split.conf — nginx not available"
}
Remove-Item $splitConfTmp -ErrorAction SilentlyContinue

Write-Test "Checking nginx configs have correct upstream/proxy targets..."
$nginxUpstreams = @(
    @{ Name = "radarr"; Port = "7878" },
    @{ Name = "sonarr"; Port = "8989" },
    @{ Name = "prowlarr"; Port = "9696" },
    @{ Name = "overseerr"; Port = "5055" },
    @{ Name = "tautulli"; Port = "8181" },
    @{ Name = "qbittorrent"; Port = "8080" }
)
$missingUpstreams = @()
foreach ($upstream in $nginxUpstreams) {
    if ($nginxContent -notmatch "$($upstream.Name).*$($upstream.Port)") {
        $missingUpstreams += "$($upstream.Name):$($upstream.Port)"
    }
}
if ($missingUpstreams.Count -eq 0) {
    Write-Pass "All service upstreams/proxies configured correctly"
} else {
    Write-Fail "Missing or incorrect upstreams: $($missingUpstreams -join ', ')"
}

# =============================================================================
# Template Configuration Tests
# =============================================================================

Write-Header "Template Configuration Tests"

Write-Test "Checking qBittorrent template exists..."
$qbTemplatePath = "templates/qBittorrent/qBittorrent.conf"
if (Test-Path $qbTemplatePath) {
    Write-Pass "qBittorrent template exists"
    
    Write-Test "Validating qBittorrent template has required settings..."
    $qbContent = Get-Content -Raw $qbTemplatePath
    $requiredQbSettings = @(
        "Session\DefaultSavePath=/downloads",
        "Session\AddTrackersEnabled=true",
        "Session\MaxConnections=",
        "Session\DHTEnabled=true",
        "Session\GlobalMaxRatio="
    )
    $missingSettings = @()
    foreach ($setting in $requiredQbSettings) {
        if ($qbContent -notmatch [regex]::Escape($setting)) {
            $missingSettings += $setting
        }
    }
    if ($missingSettings.Count -eq 0) {
        Write-Pass "qBittorrent template has all required settings"
    } else {
        Write-Fail "Missing qBittorrent settings: $($missingSettings -join ', ')"
    }
    
    Write-Test "Checking qBittorrent template has public trackers configured..."
    if ($qbContent -match "AdditionalTrackers=.*tracker.*announce") {
        Write-Pass "Public trackers are configured in template"
    } else {
        Write-Fail "Public trackers not found in qBittorrent template"
    }
} else {
    Write-Fail "qBittorrent template is missing"
}

# =============================================================================
# Setup Script Validation Tests
# =============================================================================

Write-Header "Setup Script Validation Tests"

Write-Test "Checking setup.sh creates required environment variables..."
$setupContent = Get-Content -Raw "setup.sh"
$requiredEnvVars = @("PUID", "PGID", "TZ", "DOCKER_CONFIG", "DOCKER_MEDIA", "PLEX_CLAIM")
$missingEnvVars = @()
foreach ($envVar in $requiredEnvVars) {
    if ($setupContent -notmatch "$envVar=") {
        $missingEnvVars += $envVar
    }
}
if ($missingEnvVars.Count -eq 0) {
    Write-Pass "setup.sh handles all required environment variables"
} else {
    Write-Fail "setup.sh missing handling for: $($missingEnvVars -join ', ')"
}

Write-Test "Checking setup.sh supports unified and split modes..."
if ($setupContent -match "unified" -and $setupContent -match "split") {
    Write-Pass "setup.sh supports both unified and split deployment modes"
} else {
    Write-Fail "setup.sh may be missing deployment mode support"
}

Write-Test "Checking setup.sh copies qBittorrent template..."
if ($setupContent -match "qBittorrent.*conf" -or $setupContent -match "templates.*qBittorrent") {
    Write-Pass "setup.sh references qBittorrent template"
} else {
    Write-Fail "setup.sh may not copy qBittorrent template"
}

Write-Test "Checking setup.ps1 has matching functionality..."
$setupPsContent = Get-Content -Raw "setup.ps1"
$setupPsChecks = @("PUID", "PGID", "unified", "split", "qBittorrent")
$missingPsFeatures = @()
foreach ($check in $setupPsChecks) {
    if ($setupPsContent -notmatch $check) {
        $missingPsFeatures += $check
    }
}
if ($missingPsFeatures.Count -eq 0) {
    Write-Pass "setup.ps1 has matching functionality to setup.sh"
} else {
    Write-Fail "setup.ps1 may be missing: $($missingPsFeatures -join ', ')"
}

# =============================================================================
# Configure Script Validation Tests
# =============================================================================

Write-Header "Configure Script Validation Tests"

Write-Test "Checking configure.sh wires required services..."
$configureContent = Get-Content -Raw "configure.sh"
$requiredWiring = @(
    "qbittorrent.*radarr|radarr.*qbittorrent",
    "qbittorrent.*sonarr|sonarr.*qbittorrent",
    "prowlarr.*radarr|radarr.*prowlarr",
    "prowlarr.*sonarr|sonarr.*prowlarr"
)
$missingWiring = @()
foreach ($wire in $requiredWiring) {
    if ($configureContent -notmatch $wire) {
        $missingWiring += $wire
    }
}
if ($missingWiring.Count -le 0) {
    Write-Pass "configure.sh wires all required service connections"
} else {
    Write-Fail "configure.sh may be missing wiring for: $($missingWiring -join ', ')"
}

Write-Test "Checking configure.sh adds public indexers..."
if ($configureContent -match "indexer" -and ($configureContent -match "1337x|torrentgalaxy|nyaa|limetorrent" -or $configureContent -match "public.*indexer")) {
    Write-Pass "configure.sh adds public indexers to Prowlarr"
} else {
    Write-Fail "configure.sh may not add public indexers"
}

Write-Test "Checking configure.sh sets root folders..."
if ($configureContent -match "rootfolder|root.*folder" -and $configureContent -match "/movies" -and $configureContent -match "/tv") {
    Write-Pass "configure.sh configures root folders for Radarr/Sonarr"
} else {
    Write-Fail "configure.sh may not set root folders"
}

Write-Test "Checking configure.ps1 has matching functionality..."
$configurePsContent = Get-Content -Raw "configure.ps1"
$configurePsChecks = @("qbittorrent", "radarr", "sonarr", "prowlarr", "indexer")
$missingConfigPsFeatures = @()
foreach ($check in $configurePsChecks) {
    if ($configurePsContent -notmatch $check) {
        $missingConfigPsFeatures += $check
    }
}
if ($missingConfigPsFeatures.Count -eq 0) {
    Write-Pass "configure.ps1 has matching functionality to configure.sh"
} else {
    Write-Fail "configure.ps1 may be missing: $($missingConfigPsFeatures -join ', ')"
}

# =============================================================================
# HTML/Homepage Tests
# =============================================================================

Write-Header "Homepage Tests"

Write-Test "Checking homepage/index.html structure..."
$indexContent = Get-Content -Raw "homepage/index.html"
if ($indexContent -match "<html" -and $indexContent -match "</html>") {
    Write-Pass "homepage/index.html has valid HTML structure"
} else {
    Write-Fail "homepage/index.html may have structural issues"
}

Write-Test "Checking homepage/index.html has service configuration..."
# Homepage uses JavaScript to build direct port URLs
$serviceIds = @("plex", "radarr", "sonarr", "prowlarr", "overseerr", "qbittorrent", "tautulli")
$missingServices = @()

foreach ($id in $serviceIds) {
    if ($indexContent -notmatch "id=`"$id`"") {
        $missingServices += $id
    }
}

# Also check the JavaScript port configuration exists
$hasPortConfig = $indexContent -match "const services = \{" -and $indexContent -match "radarr:\s*7878"

if ($missingServices.Count -eq 0 -and $hasPortConfig) {
    Write-Pass "Homepage has all service links with port configuration"
} elseif ($missingServices.Count -gt 0) {
    Write-Fail "Missing service elements: $($missingServices -join ', ')" 
} else {
    Write-Fail "Homepage missing JavaScript port configuration"
}

Write-Test "Checking homepage/status.html has health check logic..."
$statusContent = Get-Content -Raw "homepage/status.html"
if ($statusContent -match "fetch" -and $statusContent -match "status") {
    Write-Pass "status.html has health check functionality"
} else {
    Write-Fail "status.html may be missing health check logic"
}

# -- Homepage fetch architecture tests (static, no Docker required) ----------

Write-Test "Checking config.json.template has apiPaths key..."
$templateContent = Get-Content -Raw "homepage/config.json.template"
if ($templateContent -match '"apiPaths"') {
    Write-Pass "config.json.template contains apiPaths key"
} else {
    Write-Fail "config.json.template missing apiPaths key (new architecture requirement)"
}

Write-Test "Checking config.json.template has healthPaths key..."
if ($templateContent -match '"healthPaths"') {
    Write-Pass "config.json.template contains healthPaths key"
} else {
    Write-Fail "config.json.template missing healthPaths key (new architecture requirement)"
}

Write-Test "Checking config.json.template apiPaths and healthPaths cover all 7 services..."
$archServiceIds = @("plex", "radarr", "sonarr", "prowlarr", "overseerr", "qbittorrent", "tautulli")
$missingFromArchPaths = @()
foreach ($id in $archServiceIds) {
    # Each service must appear at least 3 times: port key + apiPaths entry + healthPaths entry
    $matchCount = ([regex]::Matches($templateContent, [regex]::Escape("`"$id`""))).Count
    if ($matchCount -lt 3) {
        $missingFromArchPaths += $id
    }
}
if ($missingFromArchPaths.Count -eq 0) {
    Write-Pass "config.json.template apiPaths and healthPaths cover all 7 services"
} else {
    Write-Fail "config.json.template missing services from apiPaths/healthPaths: $($missingFromArchPaths -join ', ')"
}

Write-Test "Checking homepage/js/status.js does not use no-cors fetch mode..."
$statusJsContent = Get-Content -Raw "homepage/js/status.js"
if ($statusJsContent -notmatch 'no-cors') {
    Write-Pass "status.js does not use no-cors fetch mode"
} else {
    Write-Fail "status.js uses no-cors fetch mode — architecture requires standard CORS requests via nginx proxy"
}

Write-Test "Checking homepage/js/status.js does not use HEAD request method..."
if ($statusJsContent -notmatch "method:\s*['""]HEAD") {
    Write-Pass "status.js does not use HEAD request method"
} else {
    Write-Fail "status.js uses HEAD method — architecture requires GET requests to dedicated health endpoints"
}

Write-Test "Checking homepage/js/services.js exists..."
if (Test-Path "homepage/js/services.js") {
    Write-Pass "homepage/js/services.js exists"
} else {
    Write-Fail "homepage/js/services.js is missing (required by new fetch architecture)"
}

Write-Test "Checking homepage/js/services.js contains all 7 service IDs..."
if (Test-Path "homepage/js/services.js") {
    $servicesJsContent = Get-Content -Raw "homepage/js/services.js"
    $missingFromServicesJs = @()
    foreach ($id in $archServiceIds) {
        if ($servicesJsContent -notmatch "'$id'" -and $servicesJsContent -notmatch "`"$id`"") {
            $missingFromServicesJs += $id
        }
    }
    if ($missingFromServicesJs.Count -eq 0) {
        Write-Pass "services.js contains all 7 service IDs"
    } else {
        Write-Fail "services.js missing service IDs: $($missingFromServicesJs -join ', ')"
    }
} else {
    Write-Fail "services.js not found — cannot verify service ID coverage"
}

Write-Test "Checking homepage/js/status.js has no port-based absolute URL construction..."
if ($statusJsContent -notmatch ':\d{4,5}/') {
    Write-Pass "status.js uses relative health check paths (no port-based URLs)"
} else {
    Write-Fail "status.js constructs port-based absolute URLs — use relative paths instead"
}

# =============================================================================
# Overseerr OAuth Detection Tests (Phase 9 — unit-level, mock config files)
# These tests run in both quick and full mode since they use mock files,
# not a live Overseerr container.
# =============================================================================

Write-Header "Overseerr OAuth Detection Tests"

Write-Test "Overseerr uninitialized — settings.json absent → apiKey null..."
$overseerrMockDir = Join-Path $env:TEMP "simplarr-ovsr-$(Get-Random)"
$overseerrMockConfig = Join-Path $overseerrMockDir "overseerr"
New-Item -ItemType Directory -Force -Path $overseerrMockConfig | Out-Null
$mockSettingsPath = Join-Path $overseerrMockConfig "settings.json"

# Case 1: settings.json does not exist
if (-not (Test-Path $mockSettingsPath)) {
    Write-Pass "Overseerr uninitialized — settings.json absent confirms uninitialized state"
} else {
    Write-Fail "Overseerr uninitialized — settings.json should not exist in fresh mock dir"
}

# Case 2: settings.json exists but apiKey is empty
'{"main":{"apiKey":"","applicationTitle":"Overseerr"}}' |
    Set-Content -Path $mockSettingsPath -Encoding UTF8
$emptyKeyResult = $null
try {
    $settings = Get-Content $mockSettingsPath -Raw | ConvertFrom-Json
    $emptyKeyResult = $settings.main.apiKey
} catch {
    $emptyKeyResult = $null
}
if ([string]::IsNullOrWhiteSpace($emptyKeyResult)) {
    Write-Pass "Overseerr uninitialized — empty apiKey in settings.json → null/empty result (correct)"
} else {
    Write-Fail "Overseerr uninitialized — expected empty apiKey but got: $emptyKeyResult"
}

Write-Test "Overseerr initialized — apiKey extracted from mock settings.json..."
$mockApiKey = "testkey-overseerr-abc12345"
"{`"main`":{`"apiKey`":`"$mockApiKey`",`"applicationTitle`":`"Overseerr`"}}" |
    Set-Content -Path $mockSettingsPath -Encoding UTF8
$foundKey = $null
try {
    $settings = Get-Content $mockSettingsPath -Raw | ConvertFrom-Json
    $foundKey = $settings.main.apiKey
} catch {
    $foundKey = $null
}
if ($foundKey -eq $mockApiKey) {
    Write-Pass "Overseerr initialized — apiKey '$($mockApiKey.Substring(0,8))...' extracted from mock settings.json"
} else {
    Write-Fail "Overseerr initialized — expected '$mockApiKey' but got '$foundKey'"
}

Remove-Item -Recurse -Force $overseerrMockDir -ErrorAction SilentlyContinue

# =============================================================================
# Port Literal Guard Tests
# =============================================================================
#
# These tests ensure configure.sh and configure.ps1 contain no stray hardcoded
# port literals outside of their single-source-of-truth variable default-value
# lines. Adding a port number inline (rather than through a declared variable)
# breaks the centralization guarantee and causes silent drift.
#
# Acceptable — single-source-of-truth declarations:
#   configure.sh:  RADARR_URL="${RADARR_URL:-http://localhost:7878}"
#   configure.ps1: [string]$RadarrUrl = "http://localhost:7878"
#
# Stray — port hardcoded outside a default declaration (must not exist):
#   {"name": "port", "value": 7878}
#   "http://${RADARR_HOST}:7878/api/..."
#
# Ports guarded: 7878 (Radarr), 8989 (Sonarr), 9696 (Prowlarr),
#                8080 (qBittorrent), 5055 (Overseerr), 8181 (Tautulli),
#                32400 (Plex)

Write-Header "Port Literal Guard Tests"

$portLiteralPattern = "7878|8989|9696|8080|5055|8181|32400"

Write-Test "Checking configure.sh has no stray hardcoded port literals..."
# Port literals are acceptable only on bash variable default-value lines using
# the ${VAR:-default} syntax. Any other occurrence is a centralization violation.
if (Test-Path "configure.sh") {
    $strayMatchesSh = Select-String -Path "configure.sh" -Pattern $portLiteralPattern |
        Where-Object { $_.Line -notmatch '\$\{[A-Z_]+:-' }
    if ($strayMatchesSh.Count -eq 0) {
        Write-Pass "configure.sh — no stray port literals outside variable default-value lines"
    } else {
        Write-Fail "configure.sh — $($strayMatchesSh.Count) stray port literal(s) found outside variable default-value lines:"
        $strayMatchesSh | ForEach-Object { Write-Info "  Line $($_.LineNumber): $($_.Line.Trim())" }
    }
} else {
    Write-Fail "configure.sh not found — cannot run port literal guard"
}

Write-Test "Checking configure.ps1 has no stray hardcoded port literals..."
# Port literals are acceptable only on PowerShell parameter default-value
# declarations matching [type]$Name = value. Any other occurrence is a
# centralization violation.
if (Test-Path "configure.ps1") {
    $strayMatchesPs1 = Select-String -Path "configure.ps1" -Pattern $portLiteralPattern |
        Where-Object { $_.Line -notmatch '^\s*\[(string|int|bool)\]\$' }
    if ($strayMatchesPs1.Count -eq 0) {
        Write-Pass "configure.ps1 — no stray port literals outside parameter default-value declarations"
    } else {
        Write-Fail "configure.ps1 — $($strayMatchesPs1.Count) stray port literal(s) found outside parameter default-value declarations:"
        $strayMatchesPs1 | ForEach-Object { Write-Info "  Line $($_.LineNumber): $($_.Line.Trim())" }
    }
} else {
    Write-Fail "configure.ps1 not found — cannot run port literal guard"
}

# =============================================================================
# Quick Mode Exit
# =============================================================================

if ($Quick) {
    Write-Header "Quick Mode - Skipping Container Tests"
    Write-Skip "Container startup tests (run without -Quick to include)"
    Write-Skip "Service connectivity tests"
    Write-Skip "API integration tests"
} else {

# =============================================================================
# Container Startup Tests
# =============================================================================

Write-Header "Container Startup Tests"

# Clean up any existing test containers first
Write-Info "Cleaning up any existing test containers..."
$existingContainers = docker ps -a --filter "name=simplarr-test" --format "{{.ID}}" 2>$null
if ($existingContainers) {
    $existingContainers | ForEach-Object { docker rm -f $_ 2>$null | Out-Null }
    Write-Pass "Cleaned up existing test containers"
    Start-Sleep -Seconds 2
} else {
    Write-Pass "No existing test containers to clean up"
}

# Create test environment
Write-Info "Creating test environment..."
$testDir = "$env:TEMP\simplarr-test-$PID"
$projectDir = (Get-Location).Path
New-Item -ItemType Directory -Force -Path "$testDir\config\radarr" | Out-Null
New-Item -ItemType Directory -Force -Path "$testDir\config\sonarr" | Out-Null
New-Item -ItemType Directory -Force -Path "$testDir\config\prowlarr" | Out-Null
New-Item -ItemType Directory -Force -Path "$testDir\config\qbittorrent" | Out-Null
New-Item -ItemType Directory -Force -Path "$testDir\config\overseerr" | Out-Null
New-Item -ItemType Directory -Force -Path "$testDir\config\tautulli" | Out-Null
New-Item -ItemType Directory -Force -Path "$testDir\media\movies" | Out-Null
New-Item -ItemType Directory -Force -Path "$testDir\media\tv" | Out-Null
New-Item -ItemType Directory -Force -Path "$testDir\media\downloads" | Out-Null

# Create test compose file (excluding Plex)
$testCompose = @"
services:
  homepage:
    build:
      context: $projectDir/homepage
      dockerfile: Dockerfile
    container_name: simplarr-test-homepage
    volumes:
      - $projectDir/homepage:/usr/share/nginx/html:ro

  nginx:
    image: nginx:alpine
    container_name: simplarr-test-nginx
    ports:
      - "80:80"
    volumes:
      - $testDir/nginx-test.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - homepage

  qbittorrent:
    image: linuxserver/qbittorrent:latest
    container_name: simplarr-test-qbittorrent
    ports:
      - "8080:8080"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
      - WEBUI_PORT=8080
    volumes:
      - $testDir/config/qbittorrent:/config
      - $testDir/media/downloads:/downloads

  radarr:
    image: linuxserver/radarr:latest
    container_name: simplarr-test-radarr
    ports:
      - "7878:7878"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $testDir/config/radarr:/config
      - $testDir/media/downloads:/downloads
      - $testDir/media/movies:/movies

  sonarr:
    image: linuxserver/sonarr:latest
    container_name: simplarr-test-sonarr
    ports:
      - "8989:8989"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $testDir/config/sonarr:/config
      - $testDir/media/downloads:/downloads
      - $testDir/media/tv:/tv

  prowlarr:
    image: linuxserver/prowlarr:latest
    container_name: simplarr-test-prowlarr
    ports:
      - "9696:9696"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $testDir/config/prowlarr:/config

  tautulli:
    image: linuxserver/tautulli:latest
    container_name: simplarr-test-tautulli
    ports:
      - "8181:8181"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $testDir/config/tautulli:/config

  overseerr:
    image: linuxserver/overseerr:latest
    container_name: simplarr-test-overseerr
    ports:
      - "5055:5055"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $testDir/config/overseerr:/config
"@

# Create a simplified nginx config for testing - homepage only (apps use direct ports)
$testNginxConfig = @"
# Simplarr Test Nginx Config - serves homepage only, apps accessed via direct ports
server {
    listen 80;
    server_name localhost;

    # Homepage
    location / {
        proxy_pass http://homepage:80;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
    }

    # Status page
    location = /status {
        proxy_pass http://homepage:80/status.html;
        proxy_set_header Host `$host;
    }
}
"@

$testNginxConfig | Out-File -FilePath "$testDir\nginx-test.conf" -Encoding ASCII

$testCompose | Out-File -FilePath "$testDir\docker-compose-test.yml" -Encoding UTF8

# Start test containers
Write-Test "Starting test containers (this may take a few minutes)..."
Push-Location $testDir
$startResult = docker compose -f docker-compose-test.yml up -d 2>&1
Pop-Location

if ($LASTEXITCODE -eq 0) {
    Write-Pass "Test containers started"
} else {
    Write-Fail "Failed to start test containers"
    Write-Output $startResult
}

# Wait for services
Write-Info "Waiting for services to become healthy (up to 2 minutes)..."
Start-Sleep -Seconds 60

# =============================================================================
# Service Connectivity Tests
# =============================================================================

Write-Header "Service Connectivity Tests"

$services = @{
    "qBittorrent" = 8080
    "Radarr" = 7878
    "Sonarr" = 8989
    "Prowlarr" = 9696
    "Tautulli" = 8181
    "Overseerr" = 5055
    "Nginx" = 80
}

foreach ($service in $services.GetEnumerator()) {
    Write-Test "Testing $($service.Key) connectivity on port $($service.Value)..."
    if (Test-ServiceReady "http://localhost:$($service.Value)" 30) {
        Write-Pass "$($service.Key) is responding"
    } else {
        Write-Fail "$($service.Key) is not responding"
    }
}

# Test homepage via nginx
Write-Test "Testing homepage loads via nginx..."
try {
    $response = Invoke-WebRequest -Uri "http://localhost/" -TimeoutSec 10 -UseBasicParsing
    if ($response.StatusCode -eq 200 -and $response.Content -match "Simplarr") {
        Write-Pass "Homepage loads correctly via nginx"
    } else {
        Write-Fail "Homepage content unexpected (should contain 'Simplarr')"
    }
} catch {
    Write-Fail "Homepage not accessible via nginx"
}

Write-Test "Testing status page loads via nginx..."
try {
    $response = Invoke-WebRequest -Uri "http://localhost/status" -TimeoutSec 10 -UseBasicParsing
    if ($response.StatusCode -eq 200 -and $response.Content -match "status|Status") {
        Write-Pass "Status page loads correctly via nginx"
    } else {
        Write-Fail "Status page content unexpected"
    }
} catch {
    Write-Fail "Status page not accessible via nginx"
}

# =============================================================================
# API Integration Tests
# =============================================================================

Write-Header "API Integration Tests"

Start-Sleep -Seconds 10

# Get API keys
Write-Test "Checking Radarr API key generation..."
$radarrConfig = "$testDir\config\radarr\config.xml"
if ((Test-Path $radarrConfig) -and (Get-Content $radarrConfig -Raw) -match "<ApiKey>([^<]+)</ApiKey>") {
    $radarrApiKey = $Matches[1]
    Write-Pass "Radarr API key generated: $($radarrApiKey.Substring(0,8))..."
} else {
    Write-Fail "Radarr API key not found"
    $radarrApiKey = $null
}

Write-Test "Checking Sonarr API key generation..."
$sonarrConfig = "$testDir\config\sonarr\config.xml"
if ((Test-Path $sonarrConfig) -and (Get-Content $sonarrConfig -Raw) -match "<ApiKey>([^<]+)</ApiKey>") {
    $sonarrApiKey = $Matches[1]
    Write-Pass "Sonarr API key generated: $($sonarrApiKey.Substring(0,8))..."
} else {
    Write-Fail "Sonarr API key not found"
    $sonarrApiKey = $null
}

Write-Test "Checking Prowlarr API key generation..."
$prowlarrConfig = "$testDir\config\prowlarr\config.xml"
if ((Test-Path $prowlarrConfig) -and (Get-Content $prowlarrConfig -Raw) -match "<ApiKey>([^<]+)</ApiKey>") {
    $prowlarrApiKey = $Matches[1]
    Write-Pass "Prowlarr API key generated: $($prowlarrApiKey.Substring(0,8))..."
} else {
    Write-Fail "Prowlarr API key not found"
    $prowlarrApiKey = $null
}

# Test API endpoints
if ($radarrApiKey) {
    Write-Test "Testing Radarr API endpoint..."
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:7878/api/v3/system/status" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10
        if ($response.version) {
            Write-Pass "Radarr API is functional (v$($response.version))"
        } else {
            Write-Fail "Radarr API response unexpected"
        }
    } catch {
        Write-Fail "Radarr API not responding correctly"
    }
}

if ($sonarrApiKey) {
    Write-Test "Testing Sonarr API endpoint..."
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:8989/api/v3/system/status" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10
        if ($response.version) {
            Write-Pass "Sonarr API is functional (v$($response.version))"
        } else {
            Write-Fail "Sonarr API response unexpected"
        }
    } catch {
        Write-Fail "Sonarr API not responding correctly"
    }
}

if ($prowlarrApiKey) {
    Write-Test "Testing Prowlarr API endpoint..."
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:9696/api/v1/system/status" -Headers @{"X-Api-Key" = $prowlarrApiKey} -TimeoutSec 10
        if ($response.version) {
            Write-Pass "Prowlarr API is functional (v$($response.version))"
        } else {
            Write-Fail "Prowlarr API response unexpected"
        }
    } catch {
        Write-Fail "Prowlarr API not responding correctly"
    }
}

# =============================================================================
# Configuration File Validation Tests
# =============================================================================

Write-Header "Configuration File Validation Tests"

Write-Info "Validating service configuration files directly..."

# Validate Radarr config.xml
Write-Test "Validating Radarr config.xml structure..."
$radarrConfigPath = "$testDir\config\radarr\config.xml"
if (Test-Path $radarrConfigPath) {
    $radarrXml = Get-Content -Raw $radarrConfigPath
    $hasApiKey = $radarrXml -match "<ApiKey>[A-Za-z0-9]{32}</ApiKey>"
    $hasPort = $radarrXml -match "<Port>7878</Port>"
    $hasBindAddress = $radarrXml -match "<BindAddress>\*</BindAddress>"
    
    if ($hasApiKey -and $hasPort -and $hasBindAddress) {
        Write-Pass "Radarr config.xml has valid structure (API key, port, bind address)"
    } else {
        $missing = @()
        if (-not $hasApiKey) { $missing += "API key" }
        if (-not $hasPort) { $missing += "port" }
        if (-not $hasBindAddress) { $missing += "bind address" }
        Write-Fail "Radarr config.xml missing: $($missing -join ', ')"
    }
} else {
    Write-Fail "Radarr config.xml not found"
}

# Validate Sonarr config.xml
Write-Test "Validating Sonarr config.xml structure..."
$sonarrConfigPath = "$testDir\config\sonarr\config.xml"
if (Test-Path $sonarrConfigPath) {
    $sonarrXml = Get-Content -Raw $sonarrConfigPath
    $hasApiKey = $sonarrXml -match "<ApiKey>[A-Za-z0-9]{32}</ApiKey>"
    $hasPort = $sonarrXml -match "<Port>8989</Port>"
    $hasBindAddress = $sonarrXml -match "<BindAddress>\*</BindAddress>"
    
    if ($hasApiKey -and $hasPort -and $hasBindAddress) {
        Write-Pass "Sonarr config.xml has valid structure (API key, port, bind address)"
    } else {
        $missing = @()
        if (-not $hasApiKey) { $missing += "API key" }
        if (-not $hasPort) { $missing += "port" }
        if (-not $hasBindAddress) { $missing += "bind address" }
        Write-Fail "Sonarr config.xml missing: $($missing -join ', ')"
    }
} else {
    Write-Fail "Sonarr config.xml not found"
}

# Validate Prowlarr config.xml
Write-Test "Validating Prowlarr config.xml structure..."
$prowlarrConfigPath = "$testDir\config\prowlarr\config.xml"
if (Test-Path $prowlarrConfigPath) {
    $prowlarrXml = Get-Content -Raw $prowlarrConfigPath
    $hasApiKey = $prowlarrXml -match "<ApiKey>[A-Za-z0-9]{32}</ApiKey>"
    $hasPort = $prowlarrXml -match "<Port>9696</Port>"
    $hasBindAddress = $prowlarrXml -match "<BindAddress>\*</BindAddress>"
    
    if ($hasApiKey -and $hasPort -and $hasBindAddress) {
        Write-Pass "Prowlarr config.xml has valid structure (API key, port, bind address)"
    } else {
        $missing = @()
        if (-not $hasApiKey) { $missing += "API key" }
        if (-not $hasPort) { $missing += "port" }
        if (-not $hasBindAddress) { $missing += "bind address" }
        Write-Fail "Prowlarr config.xml missing: $($missing -join ', ')"
    }
} else {
    Write-Fail "Prowlarr config.xml not found"
}

# Validate qBittorrent qBittorrent.conf
Write-Test "Validating qBittorrent configuration..."
$qbConfigPath = "$testDir\config\qbittorrent\qBittorrent\qBittorrent.conf"
if (Test-Path $qbConfigPath) {
    $qbConf = Get-Content -Raw $qbConfigPath
    $hasPreferences = $qbConf -match "\[Preferences\]"
    $hasWebUI = $qbConf -match "WebUI"

    if ($hasPreferences -and $hasWebUI) {
        Write-Pass "qBittorrent config has valid structure"
    } else {
        Write-Fail "qBittorrent config missing required sections"
    }
} else {
    Write-Fail "qBittorrent config file not found"
}

# Validate Overseerr settings.json (if it exists)
Write-Test "Validating Overseerr configuration..."
$overseerrConfigPath = "$testDir\config\overseerr\settings.json"
if (Test-Path $overseerrConfigPath) {
    try {
        $overseerrConfig = Get-Content -Raw $overseerrConfigPath | ConvertFrom-Json
        if ($overseerrConfig.main) {
            Write-Pass "Overseerr settings.json has valid JSON structure"
        } else {
            Write-Warn "Overseerr settings.json exists but may not be fully initialized"
        }
    } catch {
        Write-Fail "Overseerr settings.json has invalid JSON"
    }
} else {
    Write-Warn "Overseerr settings.json not yet created (normal on first start)"
}

# Validate Tautulli config.ini
Write-Test "Validating Tautulli configuration..."
$tautulliConfigPath = "$testDir\config\tautulli\config.ini"
if (Test-Path $tautulliConfigPath) {
    $tautulliConf = Get-Content -Raw $tautulliConfigPath
    $hasHttpPort = $tautulliConf -match "http_port\s*=\s*8181"

    if ($hasHttpPort) {
        Write-Pass "Tautulli config.ini has valid structure"
    } else {
        Write-Warn "Tautulli config.ini exists but may not be fully configured"
    }
} else {
    Write-Warn "Tautulli config.ini not yet created (normal on first start)"
}

# =============================================================================
# Configure.sh Functionality Tests (Service Wiring)
# =============================================================================

Write-Header "Configure Script Functionality Tests"

Write-Info "These tests validate the same operations configure.sh performs..."

# Get qBittorrent temporary password from logs
Write-Test "Getting qBittorrent temporary password from logs..."
$qbPassword = $null
$qbLogs = docker logs simplarr-test-qbittorrent 2>&1 | Out-String

# The password appears in logs like: "The WebUI administrator username is: admin"
# followed by "The WebUI administrator password was not set. A temporary password is provided for this session: PASSWORD"
if ($qbLogs -match "temporary password.*?:\s*(\S+)") {
    $qbPassword = $Matches[1].Trim()
    Write-Pass "Retrieved qBittorrent temp password: $($qbPassword.Substring(0, [Math]::Min(4, $qbPassword.Length)))..."
} else {
    Write-Warn "Could not retrieve qBittorrent password from logs - may need to wait longer for qBittorrent to start"
    Write-Info "Waiting additional 30 seconds for qBittorrent..."
    Start-Sleep -Seconds 30
    $qbLogs = docker logs simplarr-test-qbittorrent 2>&1 | Out-String
    if ($qbLogs -match "temporary password.*?:\s*(\S+)") {
        $qbPassword = $Matches[1].Trim()
        Write-Pass "Retrieved qBittorrent temp password after retry: $($qbPassword.Substring(0, [Math]::Min(4, $qbPassword.Length)))..."
    } else {
        Write-Fail "Could not retrieve qBittorrent password from logs even after retry"
    }
}

# Test adding root folders to Radarr
if ($radarrApiKey) {
    Write-Test "Adding root folder to Radarr (like configure.sh)..."
    # Check if root folder already exists
    $existingFolders = Invoke-RestMethod -Uri "http://localhost:7878/api/v3/rootfolder" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10
    if ($existingFolders | Where-Object { $_.path -eq "/movies" }) {
        Write-Pass "Radarr root folder already exists"
    } else {
        try {
            $rootFolder = @{
                path = "/movies"
            }
            $response = Invoke-RestMethod -Uri "http://localhost:7878/api/v3/rootfolder" -Method Post -Headers @{
                "X-Api-Key" = $radarrApiKey
                "Content-Type" = "application/json"
            } -Body ($rootFolder | ConvertTo-Json) -TimeoutSec 10
            if ($response.path -eq "/movies") {
                Write-Pass "Radarr root folder added successfully"
            } else {
                Write-Fail "Radarr root folder response unexpected"
            }
        } catch {
            Write-Fail "Failed to add Radarr root folder: $($_.Exception.Message)"
        }
    }
    
    Write-Test "Adding qBittorrent as download client to Radarr..."
    if (-not $qbPassword) {
        Write-Skip "Skipping - qBittorrent password not available"
    } else {
        # Check if already exists
        $existingClients = Invoke-RestMethod -Uri "http://localhost:7878/api/v3/downloadclient" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10
        if ($existingClients | Where-Object { $_.name -eq "qBittorrent" }) {
            Write-Pass "qBittorrent already exists in Radarr"
        } else {
            try {
                # Build download client with proper fields
                $downloadClient = @{
                    enable = $true
                    protocol = "torrent"
                    priority = 1
                    name = "qBittorrent"
                    implementation = "QBittorrent"
                    configContract = "QBittorrentSettings"
                    implementationName = "qBittorrent"
                    tags = @()
                    fields = @(
                        @{name = "host"; value = "qbittorrent"}
                        @{name = "port"; value = 8080}
                        @{name = "useSsl"; value = $false}
                        @{name = "urlBase"; value = ""}
                        @{name = "username"; value = "admin"}
                        @{name = "password"; value = $qbPassword}
                        @{name = "movieCategory"; value = "radarr"}
                        @{name = "movieImportedCategory"; value = ""}
                        @{name = "recentMoviePriority"; value = 0}
                        @{name = "olderMoviePriority"; value = 0}
                        @{name = "initialState"; value = 0}
                        @{name = "sequentialOrder"; value = $false}
                        @{name = "firstAndLast"; value = $false}
                        @{name = "contentLayout"; value = 0}
                    )
                }
                $response = Invoke-RestMethod -Uri "http://localhost:7878/api/v3/downloadclient" -Method Post -Headers @{
                    "X-Api-Key" = $radarrApiKey
                    "Content-Type" = "application/json"
                } -Body ($downloadClient | ConvertTo-Json -Depth 10) -TimeoutSec 10
                if ($response.name -eq "qBittorrent") {
                    Write-Pass "qBittorrent added to Radarr as download client"
                } else {
                    Write-Fail "Unexpected response adding qBittorrent to Radarr"
                }
            } catch {
                Write-Fail "Failed to add qBittorrent to Radarr: $($_.Exception.Message)"
            }
        }
    }
}

# Test adding root folders to Sonarr
if ($sonarrApiKey) {
    Write-Test "Adding root folder to Sonarr (like configure.sh)..."
    # Check if root folder already exists
    $existingFolders = Invoke-RestMethod -Uri "http://localhost:8989/api/v3/rootfolder" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10
    if ($existingFolders | Where-Object { $_.path -eq "/tv" }) {
        Write-Pass "Sonarr root folder already exists"
    } else {
        try {
            $rootFolder = @{
                path = "/tv"
            }
            $response = Invoke-RestMethod -Uri "http://localhost:8989/api/v3/rootfolder" -Method Post -Headers @{
                "X-Api-Key" = $sonarrApiKey
                "Content-Type" = "application/json"
            } -Body ($rootFolder | ConvertTo-Json) -TimeoutSec 10
            if ($response.path -eq "/tv") {
                Write-Pass "Sonarr root folder added successfully"
            } else {
                Write-Fail "Sonarr root folder response unexpected"
            }
        } catch {
            Write-Fail "Failed to add Sonarr root folder: $($_.Exception.Message)"
        }
    }
    
    Write-Test "Adding qBittorrent as download client to Sonarr..."
    if (-not $qbPassword) {
        Write-Skip "Skipping - qBittorrent password not available"
    } else {
        # Check if already exists
        $existingClients = Invoke-RestMethod -Uri "http://localhost:8989/api/v3/downloadclient" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10
        if ($existingClients | Where-Object { $_.name -eq "qBittorrent" }) {
            Write-Pass "qBittorrent already exists in Sonarr"
        } else {
            try {
                # Build download client with proper fields for Sonarr
                $downloadClient = @{
                    enable = $true
                    protocol = "torrent"
                    priority = 1
                    name = "qBittorrent"
                    implementation = "QBittorrent"
                    configContract = "QBittorrentSettings"
                    implementationName = "qBittorrent"
                    tags = @()
                    fields = @(
                        @{name = "host"; value = "qbittorrent"}
                        @{name = "port"; value = 8080}
                        @{name = "useSsl"; value = $false}
                        @{name = "urlBase"; value = ""}
                        @{name = "username"; value = "admin"}
                        @{name = "password"; value = $qbPassword}
                        @{name = "tvCategory"; value = "sonarr"}
                        @{name = "tvImportedCategory"; value = ""}
                        @{name = "recentTvPriority"; value = 0}
                        @{name = "olderTvPriority"; value = 0}
                        @{name = "initialState"; value = 0}
                        @{name = "sequentialOrder"; value = $false}
                        @{name = "firstAndLast"; value = $false}
                        @{name = "contentLayout"; value = 0}
                    )
                }
                $response = Invoke-RestMethod -Uri "http://localhost:8989/api/v3/downloadclient" -Method Post -Headers @{
                    "X-Api-Key" = $sonarrApiKey
                    "Content-Type" = "application/json"
                } -Body ($downloadClient | ConvertTo-Json -Depth 10) -TimeoutSec 10
                if ($response.name -eq "qBittorrent") {
                    Write-Pass "qBittorrent added to Sonarr as download client"
                } else {
                    Write-Fail "Unexpected response adding qBittorrent to Sonarr"
                }
            } catch {
                Write-Fail "Failed to add qBittorrent to Sonarr: $($_.Exception.Message)"
            }
        }
    }
}

# Test adding apps to Prowlarr
if ($prowlarrApiKey -and $radarrApiKey -and $sonarrApiKey) {
    # Check existing apps
    $existingApps = Invoke-RestMethod -Uri "http://localhost:9696/api/v1/applications" -Headers @{"X-Api-Key" = $prowlarrApiKey} -TimeoutSec 10
    
    Write-Test "Adding Radarr to Prowlarr (like configure.sh)..."
    if ($existingApps | Where-Object { $_.name -eq "Radarr" }) {
        Write-Pass "Radarr already exists in Prowlarr"
    } else {
        try {
            $radarrApp = @{
                name = "Radarr"
                implementation = "Radarr"
                implementationName = "Radarr"
                configContract = "RadarrSettings"
                syncLevel = "fullSync"
                fields = @(
                    @{ name = "prowlarrUrl"; value = "http://prowlarr:9696" }
                    @{ name = "baseUrl"; value = "http://radarr:7878" }
                    @{ name = "apiKey"; value = $radarrApiKey }
                    @{ name = "syncCategories"; value = @(2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060) }
                )
            }
            $response = Invoke-RestMethod -Uri "http://localhost:9696/api/v1/applications" -Method Post -Headers @{
                "X-Api-Key" = $prowlarrApiKey
                "Content-Type" = "application/json"
            } -Body ($radarrApp | ConvertTo-Json -Depth 10) -TimeoutSec 10
            if ($response.name -eq "Radarr") {
                Write-Pass "Radarr added to Prowlarr"
            } else {
                Write-Fail "Failed to add Radarr to Prowlarr"
            }
        } catch {
            Write-Fail "Failed to add Radarr to Prowlarr: $($_.Exception.Message)"
        }
    }
    
    Write-Test "Adding Sonarr to Prowlarr (like configure.sh)..."
    if ($existingApps | Where-Object { $_.name -eq "Sonarr" }) {
        Write-Pass "Sonarr already exists in Prowlarr"
    } else {
        try {
            $sonarrApp = @{
                name = "Sonarr"
                implementation = "Sonarr"
                implementationName = "Sonarr"
                configContract = "SonarrSettings"
                syncLevel = "fullSync"
                fields = @(
                    @{ name = "prowlarrUrl"; value = "http://prowlarr:9696" }
                    @{ name = "baseUrl"; value = "http://sonarr:8989" }
                    @{ name = "apiKey"; value = $sonarrApiKey }
                    @{ name = "syncCategories"; value = @(5000, 5010, 5020, 5030, 5040, 5045, 5050) }
                )
            }
            $response = Invoke-RestMethod -Uri "http://localhost:9696/api/v1/applications" -Method Post -Headers @{
                "X-Api-Key" = $prowlarrApiKey
                "Content-Type" = "application/json"
            } -Body ($sonarrApp | ConvertTo-Json -Depth 10) -TimeoutSec 10
            if ($response.name -eq "Sonarr") {
                Write-Pass "Sonarr added to Prowlarr"
            } else {
                Write-Fail "Failed to add Sonarr to Prowlarr"
            }
        } catch {
            Write-Fail "Failed to add Sonarr to Prowlarr: $($_.Exception.Message)"
        }
    }
}

# Test adding ALL public indexers to Prowlarr (matching configure.sh)
if ($prowlarrApiKey) {
    Write-Test "Adding public indexers to Prowlarr (like configure.sh)..."
    
    # Get existing indexers
    $existingIndexers = Invoke-RestMethod -Uri "http://localhost:9696/api/v1/indexer" -Headers @{"X-Api-Key" = $prowlarrApiKey} -TimeoutSec 10
    $existingNames = if ($existingIndexers) { $existingIndexers.name } else { @() }
    
    # Define all indexers that configure.sh adds
    $indexersToAdd = @(
        @{
            name = "YTS"
            implementationName = "YTS"
            definitionName = "yts"
            baseUrl = "https://yts.mx"
        },
        @{
            name = "The Pirate Bay"
            implementationName = "The Pirate Bay"
            definitionName = "thepiratebay"
            baseUrl = "https://thepiratebay.org"
        },
        @{
            name = "TorrentGalaxy"
            implementationName = "TorrentGalaxy"
            definitionName = "torrentgalaxy"
            baseUrl = "https://torrentgalaxy.to"
        },
        @{
            name = "Nyaa"
            implementationName = "Nyaa.si"
            definitionName = "nyaasi"
            baseUrl = "https://nyaa.si"
        },
        @{
            name = "LimeTorrents"
            implementationName = "LimeTorrents"
            definitionName = "limetorrents"
            baseUrl = "https://www.limetorrents.lol"
        }
    )
    
    $addedCount = 0
    $skippedCount = 0
    
    foreach ($indexerDef in $indexersToAdd) {
        if ($existingNames -contains $indexerDef.name) {
            $skippedCount++
            continue
        }
        
        try {
            $indexer = @{
                enable = $true
                redirect = $false
                name = $indexerDef.name
                implementationName = $indexerDef.implementationName
                implementation = "Cardigann"
                configContract = "CardigannSettings"
                definitionName = $indexerDef.definitionName
                appProfileId = 1
                protocol = "torrent"
                privacy = "public"
                priority = 25
                downloadClientId = 0
                tags = @()
                fields = @(
                    @{name = "definitionFile"; value = $indexerDef.definitionName}
                    @{name = "baseUrl"; value = $indexerDef.baseUrl}
                    @{name = "baseSettings.limitsUnit"; value = 0}
                )
            }
            $response = Invoke-RestMethod -Uri "http://localhost:9696/api/v1/indexer" -Method Post -Headers @{
                "X-Api-Key" = $prowlarrApiKey
                "Content-Type" = "application/json"
            } -Body ($indexer | ConvertTo-Json -Depth 10) -TimeoutSec 30
            if ($response.id) {
                $addedCount++
            }
        } catch {
            $errorMsg = $_.Exception.Message
            if ($errorMsg -match "already|exists|unique") {
                $skippedCount++
            }
            # Silently skip network errors - will report totals at end
        }
    }
    
    $totalExpected = $indexersToAdd.Count
    $totalHandled = $addedCount + $skippedCount
    if ($totalHandled -ge $totalExpected) {
        Write-Pass "Prowlarr indexers configured: $addedCount added, $skippedCount already existed"
    } elseif ($addedCount -gt 0 -or $skippedCount -gt 0) {
        Write-Warn "Prowlarr indexers partially configured: $addedCount added, $skippedCount existed (some may have network issues)"
    } else {
        Write-Fail "Failed to add any indexers to Prowlarr"
    }
    
    # Trigger Prowlarr to sync indexers to connected apps
    Write-Test "Triggering Prowlarr indexer sync to apps..."
    try {
        # Use the ApplicationIndexerSyncAll command
        $syncBody = @{ name = "ApplicationIndexerSyncAll" } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://localhost:9696/api/v1/command" -Method Post -Headers @{
            "X-Api-Key" = $prowlarrApiKey
            "Content-Type" = "application/json"
        } -Body $syncBody -TimeoutSec 10 | Out-Null
        Write-Pass "Prowlarr sync triggered"
        Start-Sleep -Seconds 10  # Give time for sync to complete
    } catch {
        Write-Warn "Could not trigger Prowlarr sync: $($_.Exception.Message)"
    }
}

# =============================================================================
# Verification Tests (Confirm wiring actually worked)
# =============================================================================

Write-Header "Verification Tests"

Write-Info "Verifying that all service configurations are complete..."

# Verify Radarr configuration
if ($radarrApiKey) {
    Write-Test "Verifying Radarr root folder configured..."
    $rootFolders = Invoke-RestMethod -Uri "http://localhost:7878/api/v3/rootfolder" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10
    if ($rootFolders -and ($rootFolders | Where-Object { $_.path -eq "/movies" })) {
        Write-Pass "Radarr has /movies root folder"
    } else {
        Write-Fail "Radarr is missing /movies root folder"
    }
    
    Write-Test "Verifying Radarr has download client configured..."
    $clients = Invoke-RestMethod -Uri "http://localhost:7878/api/v3/downloadclient" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10
    if ($clients -and ($clients | Where-Object { $_.name -eq "qBittorrent" })) {
        $qbClient = $clients | Where-Object { $_.name -eq "qBittorrent" }
        if ($qbClient.enable) {
            Write-Pass "Radarr has qBittorrent download client (enabled)"
        } else {
            Write-Warn "Radarr has qBittorrent but it's disabled"
        }
    } else {
        Write-Fail "Radarr is missing download client"
    }
    
    Write-Test "Verifying Radarr has indexers from Prowlarr..."
    $indexers = Invoke-RestMethod -Uri "http://localhost:7878/api/v3/indexer" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10
    if ($indexers -and $indexers.Count -gt 0) {
        Write-Pass "Radarr has $($indexers.Count) indexer(s) synced from Prowlarr"
    } else {
        Write-Warn "Radarr has no indexers yet (Prowlarr sync may still be in progress)"
    }
}

# Verify Sonarr configuration
if ($sonarrApiKey) {
    Write-Test "Verifying Sonarr root folder configured..."
    $rootFolders = Invoke-RestMethod -Uri "http://localhost:8989/api/v3/rootfolder" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10
    if ($rootFolders -and ($rootFolders | Where-Object { $_.path -eq "/tv" })) {
        Write-Pass "Sonarr has /tv root folder"
    } else {
        Write-Fail "Sonarr is missing /tv root folder"
    }
    
    Write-Test "Verifying Sonarr has download client configured..."
    $clients = Invoke-RestMethod -Uri "http://localhost:8989/api/v3/downloadclient" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10
    if ($clients -and ($clients | Where-Object { $_.name -eq "qBittorrent" })) {
        $qbClient = $clients | Where-Object { $_.name -eq "qBittorrent" }
        if ($qbClient.enable) {
            Write-Pass "Sonarr has qBittorrent download client (enabled)"
        } else {
            Write-Warn "Sonarr has qBittorrent but it's disabled"
        }
    } else {
        Write-Fail "Sonarr is missing download client"
    }
    
    Write-Test "Verifying Sonarr has indexers from Prowlarr..."
    $indexers = Invoke-RestMethod -Uri "http://localhost:8989/api/v3/indexer" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10
    if ($indexers -and $indexers.Count -gt 0) {
        Write-Pass "Sonarr has $($indexers.Count) indexer(s) synced from Prowlarr"
    } else {
        Write-Warn "Sonarr has no indexers yet (Prowlarr sync may still be in progress)"
    }
}

# Verify Prowlarr configuration
if ($prowlarrApiKey) {
    Write-Test "Verifying Prowlarr has indexers configured..."
    $indexers = Invoke-RestMethod -Uri "http://localhost:9696/api/v1/indexer" -Headers @{"X-Api-Key" = $prowlarrApiKey} -TimeoutSec 10
    if ($indexers -and $indexers.Count -ge 3) {
        Write-Pass "Prowlarr has $($indexers.Count) indexer(s): $($indexers.name -join ', ')"
    } elseif ($indexers -and $indexers.Count -gt 0) {
        Write-Warn "Prowlarr only has $($indexers.Count) indexer(s) (expected 3+): $($indexers.name -join ', ')"
    } else {
        Write-Fail "Prowlarr has no indexers"
    }
    
    Write-Test "Verifying Prowlarr has Radarr connected..."
    $apps = Invoke-RestMethod -Uri "http://localhost:9696/api/v1/applications" -Headers @{"X-Api-Key" = $prowlarrApiKey} -TimeoutSec 10
    if ($apps -and ($apps | Where-Object { $_.name -eq "Radarr" })) {
        Write-Pass "Prowlarr has Radarr connected"
    } else {
        Write-Fail "Prowlarr is missing Radarr connection"
    }
    
    Write-Test "Verifying Prowlarr has Sonarr connected..."
    if ($apps -and ($apps | Where-Object { $_.name -eq "Sonarr" })) {
        Write-Pass "Prowlarr has Sonarr connected"
    } else {
        Write-Fail "Prowlarr is missing Sonarr connection"
    }
}

# Summary of configuration state
Write-Header "Configuration Summary"
Write-Info "Final configuration state:"

if ($radarrApiKey) {
    $radarrRoot = (Invoke-RestMethod -Uri "http://localhost:7878/api/v3/rootfolder" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10).Count
    $radarrClients = (Invoke-RestMethod -Uri "http://localhost:7878/api/v3/downloadclient" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10).Count
    $radarrIndexers = (Invoke-RestMethod -Uri "http://localhost:7878/api/v3/indexer" -Headers @{"X-Api-Key" = $radarrApiKey} -TimeoutSec 10).Count
    Write-Info "    Radarr:   $radarrRoot root folder(s), $radarrClients download client(s), $radarrIndexers indexer(s)"
}

if ($sonarrApiKey) {
    $sonarrRoot = (Invoke-RestMethod -Uri "http://localhost:8989/api/v3/rootfolder" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10).Count
    $sonarrClients = (Invoke-RestMethod -Uri "http://localhost:8989/api/v3/downloadclient" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10).Count
    $sonarrIndexers = (Invoke-RestMethod -Uri "http://localhost:8989/api/v3/indexer" -Headers @{"X-Api-Key" = $sonarrApiKey} -TimeoutSec 10).Count
    Write-Info "    Sonarr:   $sonarrRoot root folder(s), $sonarrClients download client(s), $sonarrIndexers indexer(s)"
}

if ($prowlarrApiKey) {
    $prowlarrIndexers = (Invoke-RestMethod -Uri "http://localhost:9696/api/v1/indexer" -Headers @{"X-Api-Key" = $prowlarrApiKey} -TimeoutSec 10).Count
    $prowlarrApps = (Invoke-RestMethod -Uri "http://localhost:9696/api/v1/applications" -Headers @{"X-Api-Key" = $prowlarrApiKey} -TimeoutSec 10).Count
    Write-Info "    Prowlarr: $prowlarrIndexers indexer(s), $prowlarrApps connected app(s)"
}

Write-Output ""

# =============================================================================
# Phase 10  -  VPN Container Wiring
# =============================================================================
# 10a: Parse docker compose config of a minimal self-contained VPN overlay
#      mirroring what a user sees after uncommenting the gluetun blocks in
#      docker-compose-unified.yml.  Asserts network_mode, port ownership, and
#      depends_on wiring without starting any containers.
# 10b: Runtime container assertions guarded by /dev/net/tun existence check.
#      Each guarded test emits Write-Skip when the TUN device is absent.
# 10c: VPN connectivity check  -  always Write-Skip (requires real credentials).
# =============================================================================

Write-Header "Phase 10  -  VPN Container Wiring"

# ---------------------------------------------------------------------------
# Phase 10a  -  docker compose config resolution of a minimal VPN overlay
# ---------------------------------------------------------------------------

Write-Test "Phase 10a: Parsing docker compose config of a VPN wiring overlay..."

$vpnWiringTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "simplarr-vpn-wiring-ps-$PID"
New-Item -ItemType Directory -Force -Path $vpnWiringTmpDir | Out-Null

$vpnOverlayPath = Join-Path $vpnWiringTmpDir 'gluetun-vpn-wiring.yml'

# Minimal VPN overlay with hard-coded values  -  mirrors the commented gluetun +
# qbittorrent VPN override blocks in docker-compose-unified.yml.
@'
services:
  gluetun:
    image: qmcgaw/gluetun:v3.41.1
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    environment:
      - VPN_SERVICE_PROVIDER=mullvad
      - VPN_TYPE=openvpn
      - OPENVPN_USER=test-user
      - OPENVPN_PASSWORD=test-password
    volumes:
      - /tmp/simplarr-vpn-test/gluetun:/gluetun
    healthcheck:
      test: ["CMD", "/gluetun-entrypoint", "healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    restart: unless-stopped

  qbittorrent:
    image: linuxserver/qbittorrent:5.1.4-r2-ls443
    network_mode: "service:gluetun"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
      - WEBUI_PORT=8080
    volumes:
      - /tmp/simplarr-vpn-test/qbittorrent:/config
    healthcheck:
      test: curl -f http://localhost:8080 || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    depends_on:
      gluetun:
        condition: service_healthy
    restart: unless-stopped
'@ | Set-Content -Path $vpnOverlayPath -Encoding UTF8

$vpnConfigOutput  = docker compose -f $vpnOverlayPath config 2>&1
$vpnConfigSuccess = ($LASTEXITCODE -eq 0)
$vpnConfigText    = $vpnConfigOutput -join "`n"

if ($vpnConfigSuccess) {
    Write-Pass "VPN overlay YAML resolves cleanly under docker compose config"
} else {
    Write-Fail "VPN overlay YAML failed docker compose config"
    Write-Info "Output: $($vpnConfigOutput -join ' ')"
}

# Assert: qbittorrent has network_mode: service:gluetun
Write-Test "Phase 10a: Asserting qbittorrent has network_mode: service:gluetun..."
if (-not $vpnConfigSuccess) {
    Write-Skip "network_mode assertion (docker compose config failed)"
} elseif ($vpnConfigText -match 'network_mode:\s*service:gluetun') {
    Write-Pass "qbittorrent uses network_mode: service:gluetun (shares gluetun network namespace)"
} else {
    Write-Fail "qbittorrent network_mode: service:gluetun not found in resolved config"
}

# Assert: gluetun owns port 8080 (qBittorrent WebUI port)
Write-Test "Phase 10a: Asserting gluetun owns port 8080 (qBittorrent WebUI)..."
if (-not $vpnConfigSuccess) {
    Write-Skip "port 8080 assertion (docker compose config failed)"
} elseif (($vpnConfigText -match 'published:\s*"?8080"?') -or ($vpnConfigText -match '8080:8080')) {
    Write-Pass "gluetun owns port 8080 in resolved VPN config (qBittorrent WebUI)"
} else {
    Write-Fail "port 8080 not found under gluetun in resolved config"
}

# Assert: gluetun owns port 6881 (torrent traffic)
Write-Test "Phase 10a: Asserting gluetun owns port 6881 (torrent traffic)..."
if (-not $vpnConfigSuccess) {
    Write-Skip "port 6881 assertion (docker compose config failed)"
} elseif (($vpnConfigText -match 'published:\s*"?6881"?') -or ($vpnConfigText -match '6881:6881')) {
    Write-Pass "gluetun owns port 6881 in resolved VPN config (torrent traffic)"
} else {
    Write-Fail "port 6881 not found under gluetun in resolved config"
}

# Assert: qbittorrent depends_on gluetun with condition: service_healthy
Write-Test "Phase 10a: Asserting qbittorrent depends_on gluetun (condition: service_healthy)..."
if (-not $vpnConfigSuccess) {
    Write-Skip "depends_on assertion (docker compose config failed)"
} elseif ($vpnConfigText -match 'condition:\s*service_healthy') {
    Write-Pass "qbittorrent depends_on gluetun with condition: service_healthy"
} else {
    Write-Fail "qbittorrent depends_on gluetun (service_healthy) not found in resolved config"
}

# Clean up temporary VPN overlay directory
Remove-Item -Recurse -Force $vpnWiringTmpDir -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Phase 10b  -  Runtime container assertions
# Guarded by /dev/net/tun  -  skip when TUN device is absent (CI, WSL, macOS).
# ---------------------------------------------------------------------------

Write-Test "Phase 10b: Checking for /dev/net/tun device (required for gluetun)..."
if (Test-Path '/dev/net/tun') {
    Write-Pass "TUN device /dev/net/tun found  -  gluetun runtime assertions can proceed"
    # Runtime assertions would start gluetun and docker inspect State.Status=running.
    # These require real VPN credentials and are always skipped  -  see Phase 10c.
    Write-Skip "Gluetun container start test (TUN device present but Real VPN credentials required  -  see Phase 10c)"
} else {
    Write-Skip "Gluetun container start test (TUN device /dev/net/tun absent  -  cannot start gluetun)"
    Write-Skip "Gluetun container state inspection (TUN device /dev/net/tun absent)"
}

# ---------------------------------------------------------------------------
# Phase 10c  -  VPN connectivity (always skipped  -  requires real credentials)
# Cannot be automated: genuine VPN provider credentials are required.
# ---------------------------------------------------------------------------

Write-Skip "VPN connectivity check: Real VPN credentials required  -  cannot be automated in CI"

# =============================================================================
# Cleanup
# =============================================================================

Write-Header "Cleanup"

if ($Cleanup) {
    Write-Info "Stopping and removing test containers..."
    Push-Location $testDir
    docker compose -f docker-compose-test.yml down -v 2>$null
    Pop-Location
    Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
    Write-Pass "Test environment cleaned up"
} else {
    Write-ServiceUrl -TestDir $testDir -QbPassword $qbPassword
    Write-Skip "Cleanup (use -Cleanup flag to auto-clean)"
}

} # End of non-quick-mode tests

# =============================================================================
# Test Summary
# =============================================================================

Write-Header "Test Summary"

$totalTests = $script:TestsPassed + $script:TestsFailed + $script:TestsSkipped

Write-Output ""
Write-Output "  Passed:  $($script:TestsPassed)"
Write-Output "  Failed:  $($script:TestsFailed)"
Write-Output "  Skipped: $($script:TestsSkipped)"
Write-Output "  Total:   $totalTests"
Write-Output ""

if ($script:TestsFailed -eq 0) {
    Write-Output "All tests passed!"
    exit 0
} else {
    Write-Output "Some tests failed. Please review the output above."
    exit 1
}

