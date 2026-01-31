#===============================================================================
# Simplarr Pre-flight Validation Script (PowerShell)
#
# This script checks your system is ready to run the Simplarr stack.
# Run this BEFORE running docker-compose to catch common issues early.
#
# Usage: .\preflight.ps1 [-EnvFile <path>]
#   -EnvFile: Optional path to .env file (default: .env in current directory)
#
# Exit Codes:
#   0 - All checks passed
#   1 - Critical checks failed (stack won't work)
#   2 - Warnings only (stack may work but with issues)
#===============================================================================

[CmdletBinding()]
param(
    [Parameter()]
    [string]$EnvFile = ".env"
)

# Enable strict mode for better error catching
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

# Counters
$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

# Ports to check
$PortsToCheck = @{
    80    = "nginx (HTTP)"
    443   = "nginx (HTTPS)"
    32400 = "Plex Media Server"
    8080  = "qBittorrent WebUI"
    7878  = "Radarr"
    8989  = "Sonarr"
    9696  = "Prowlarr"
    5055  = "Overseerr"
    8181  = "Tautulli"
}

# Required environment variables
$RequiredVars = @("DOCKER_CONFIG", "DOCKER_MEDIA", "PUID", "PGID", "TZ")
$PlaceholderValues = @("your-", "change-me", "placeholder", "xxx", "CHANGEME")

# Required media subdirectories
$RequiredSubdirs = @("movies", "tv", "downloads")

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$ForegroundColor = "White"
    )
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Print-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Print-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor White -NoNewline
    Write-Host ""
    Write-Host ("-" * 78) -ForegroundColor Blue
}

function Pass {
    param([string]$Message)
    Write-Host "  " -NoNewline
    Write-Host "[PASS]" -ForegroundColor Green -NoNewline
    Write-Host " $Message"
    $script:PassCount++
}

function Fail {
    param(
        [string]$Message,
        [string]$Suggestion
    )
    Write-Host "  " -NoNewline
    Write-Host "[FAIL]" -ForegroundColor Red -NoNewline
    Write-Host " $Message"
    Write-Host "         -> Suggestion: " -NoNewline -ForegroundColor Yellow
    Write-Host $Suggestion -ForegroundColor Yellow
    $script:FailCount++
}

function Warn {
    param(
        [string]$Message,
        [string]$Note
    )
    Write-Host "  " -NoNewline
    Write-Host "[WARN]" -ForegroundColor Yellow -NoNewline
    Write-Host " $Message"
    Write-Host "         -> Note: " -NoNewline -ForegroundColor Yellow
    Write-Host $Note -ForegroundColor Yellow
    $script:WarnCount++
}

function Info {
    param([string]$Message)
    Write-Host "  " -NoNewline
    Write-Host "[INFO]" -ForegroundColor Blue -NoNewline
    Write-Host " $Message"
}

function Test-PortInUse {
    param([int]$Port)
    
    try {
        $connections = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        return ($null -ne $connections -and $connections.Count -gt 0)
    }
    catch {
        # Fallback method using netstat
        try {
            $netstat = netstat -an | Select-String ":$Port\s"
            return ($null -ne $netstat)
        }
        catch {
            return $false
        }
    }
}

function Get-EnvVariable {
    param([string]$VarName)
    
    if (Test-Path $EnvFile) {
        $content = Get-Content $EnvFile -ErrorAction SilentlyContinue
        foreach ($line in $content) {
            if ($line -match "^$VarName=(.*)$") {
                $value = $matches[1].Trim()
                # Remove surrounding quotes if present
                $value = $value -replace '^["'']|["'']$', ''
                return $value
            }
        }
    }
    return $null
}

function Test-IsPlaceholder {
    param([string]$Value)
    
    foreach ($placeholder in $PlaceholderValues) {
        if ($Value -like "*$placeholder*") {
            return $true
        }
    }
    return $false
}

#-------------------------------------------------------------------------------
# Main Script
#-------------------------------------------------------------------------------

Print-Header "Simplarr Pre-flight Validation"

Write-Host ""
Info "Running pre-flight checks for Simplarr..."
Info "Environment file: $EnvFile"
Info "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Info "PowerShell Version: $($PSVersionTable.PSVersion)"

#===============================================================================
# 1. DOCKER INSTALLATION CHECK
#===============================================================================
Print-Section "Docker Installation"

# Check if Docker is installed
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerCmd) {
    Pass "Docker is installed"
    
    # Get Docker version
    try {
        $dockerVersion = docker --version 2>$null
        Info "Version: $dockerVersion"
    }
    catch {
        Info "Could not retrieve Docker version"
    }
    
    # Check if Docker daemon is running
    try {
        $dockerInfo = docker info 2>$null
        if ($LASTEXITCODE -eq 0) {
            Pass "Docker daemon is running"
        }
        else {
            Fail "Docker daemon is not running" "Start Docker Desktop from the Start Menu or System Tray"
        }
    }
    catch {
        Fail "Docker daemon is not responding" "Start Docker Desktop from the Start Menu or System Tray"
    }
}
else {
    Fail "Docker is not installed" "Install Docker Desktop from https://docs.docker.com/desktop/install/windows-install/"
}

# Check if Docker Compose is available
try {
    $composeVersion = docker compose version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Pass "Docker Compose is available"
        Info "Version: $composeVersion"
    }
    else {
        throw "Docker Compose not available"
    }
}
catch {
    # Try legacy docker-compose
    $legacyCompose = Get-Command docker-compose -ErrorAction SilentlyContinue
    if ($legacyCompose) {
        Warn "Using legacy docker-compose" "Consider upgrading to Docker Compose V2 (docker compose)"
        try {
            $legacyVersion = docker-compose --version 2>$null
            Info "Version: $legacyVersion"
        }
        catch { }
    }
    else {
        Fail "Docker Compose is not available" "Install Docker Desktop which includes Docker Compose"
    }
}

#===============================================================================
# 2. ENVIRONMENT FILE CHECK
#===============================================================================
Print-Section "Environment Configuration"

if (Test-Path $EnvFile) {
    Pass "Environment file exists: $EnvFile"
    
    foreach ($var in $RequiredVars) {
        $value = Get-EnvVariable -VarName $var
        
        if ([string]::IsNullOrWhiteSpace($value)) {
            Fail "$var is not set" "Add $var=<value> to your $EnvFile file"
        }
        elseif (Test-IsPlaceholder -Value $value) {
            Fail "$var contains placeholder value" "Replace the placeholder in $EnvFile with your actual value"
        }
        else {
            Pass "$var is configured"
            Info "  Value: $value"
        }
    }
}
else {
    Fail "Environment file not found: $EnvFile" "Copy .env.example to .env and configure your settings"
}

#===============================================================================
# 3. PATH VALIDATION
#===============================================================================
Print-Section "Path Validation"

$dockerConfig = Get-EnvVariable -VarName "DOCKER_CONFIG"
$dockerMedia = Get-EnvVariable -VarName "DOCKER_MEDIA"

# Check DOCKER_CONFIG path
if (-not [string]::IsNullOrWhiteSpace($dockerConfig)) {
    if (Test-Path $dockerConfig -PathType Container) {
        Pass "DOCKER_CONFIG directory exists: $dockerConfig"
        
        # Check if writable (try to create a temp file)
        $testFile = Join-Path $dockerConfig ".preflight_test_$(Get-Random)"
        try {
            [IO.File]::WriteAllText($testFile, "test")
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            Pass "DOCKER_CONFIG is writable"
        }
        catch {
            Fail "DOCKER_CONFIG is not writable" "Check folder permissions - you may need to run as Administrator"
        }
    }
    else {
        Warn "DOCKER_CONFIG directory doesn't exist: $dockerConfig" "It will be created when containers start, but you may want to create it manually"
    }
}
else {
    Info "DOCKER_CONFIG not set (skipping path check)"
}

# Check DOCKER_MEDIA path
if (-not [string]::IsNullOrWhiteSpace($dockerMedia)) {
    if (Test-Path $dockerMedia -PathType Container) {
        Pass "DOCKER_MEDIA directory exists: $dockerMedia"
        
        # Check for required subdirectories
        foreach ($subdir in $RequiredSubdirs) {
            $subpath = Join-Path $dockerMedia $subdir
            if (Test-Path $subpath -PathType Container) {
                Pass "Subdirectory exists: $subdir/"
            }
            else {
                Warn "Subdirectory missing: $subdir/" "Create it with: New-Item -ItemType Directory -Path '$subpath'"
            }
        }
    }
    else {
        Fail "DOCKER_MEDIA directory doesn't exist: $dockerMedia" "Create the directory or update the path in $EnvFile"
    }
}
else {
    Info "DOCKER_MEDIA not set (skipping path check)"
}

#===============================================================================
# 4. PORT AVAILABILITY CHECK
#===============================================================================
Print-Section "Port Availability"

foreach ($port in $PortsToCheck.Keys | Sort-Object) {
    $service = $PortsToCheck[$port]
    
    if (Test-PortInUse -Port $port) {
        Fail "Port $port is in use ($service)" "Stop the service using this port or change the port mapping in docker-compose.yml"
    }
    else {
        Pass "Port $port is available ($service)"
    }
}

#===============================================================================
# 5. NETWORK CONNECTIVITY CHECK
#===============================================================================
Print-Section "Network Connectivity"

# Check Docker Hub connectivity
Info "Testing Docker Hub connectivity..."
try {
    $pullResult = docker pull hello-world 2>&1
    if ($LASTEXITCODE -eq 0) {
        Pass "Can connect to Docker Hub"
        # Clean up the test image
        docker rmi hello-world 2>$null | Out-Null
    }
    else {
        Fail "Cannot connect to Docker Hub" "Check your internet connection and firewall settings"
    }
}
catch {
    Fail "Cannot connect to Docker Hub" "Check your internet connection and firewall settings"
}

# Check general internet connectivity
Info "Testing internet connectivity..."
try {
    $ping = Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ping) {
        Pass "Internet connectivity OK"
    }
    else {
        Warn "Cannot reach external network" "Check your internet connection"
    }
}
catch {
    Warn "Could not test internet connectivity" "Test-Connection may require administrator privileges"
}

#===============================================================================
# SUMMARY
#===============================================================================
Print-Header "Summary"

Write-Host ""
Write-Host "  Passed:   " -NoNewline
Write-Host $script:PassCount -ForegroundColor Green
Write-Host "  Failed:   " -NoNewline
Write-Host $script:FailCount -ForegroundColor Red
Write-Host "  Warnings: " -NoNewline
Write-Host $script:WarnCount -ForegroundColor Yellow
Write-Host ""

if ($script:FailCount -eq 0 -and $script:WarnCount -eq 0) {
    Write-Host "  " -NoNewline
    Write-Host "All checks passed! Your system is ready." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. Review your $EnvFile settings" -ForegroundColor Gray
    Write-Host "    2. Run: " -ForegroundColor Gray -NoNewline
    Write-Host "docker compose up -d" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}
elseif ($script:FailCount -eq 0) {
    Write-Host "  " -NoNewline
    Write-Host "Checks passed with warnings. Review the issues above." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  The stack should work, but you may experience some issues." -ForegroundColor Gray
    Write-Host "  Consider fixing the warnings before proceeding." -ForegroundColor Gray
    Write-Host ""
    exit 2
}
else {
    Write-Host "  " -NoNewline
    Write-Host "Critical issues found! Please fix them before proceeding." -ForegroundColor Red
    Write-Host ""
    Write-Host "  The stack will NOT work correctly until these issues are resolved." -ForegroundColor Gray
    Write-Host "  Review the suggestions above for each failed check." -ForegroundColor Gray
    Write-Host ""
    exit 1
}
