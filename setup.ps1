# =============================================================================
# Simplarr - Interactive Setup Script (PowerShell)
# =============================================================================
# This script will help you configure your .env file for the media server stack
# Compatible with Windows PowerShell 5.1+ and PowerShell Core 7+
# =============================================================================

# Ensure we're running with proper encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Script directory and .env file path
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $ScriptDir ".env"

# =============================================================================
# Helper Functions
# =============================================================================

function Write-ColorText {
    param(
        [string]$Text,
        [ConsoleColor]$Color = 'White'
    )
    Write-Host $Text -ForegroundColor $Color -NoNewline
}

function Write-Header {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║  " -ForegroundColor Magenta -NoNewline
    Write-Host "Simplarr - Interactive Setup" -ForegroundColor Cyan -NoNewline
    Write-Host "                                  ║" -ForegroundColor Magenta
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[!] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Error {
    param([string]$Message)
    Write-Host "[X] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Info {
    param([string]$Message)
    Write-Host "[i] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-Hint {
    param([string]$Message)
    Write-Host "    Hint: " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Read-UserInput {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )
    
    if ($Default) {
        $fullPrompt = "  $Prompt [$Default]: "
    } else {
        $fullPrompt = "  ${Prompt}: "
    }
    
    $input = Read-Host $fullPrompt
    if ([string]::IsNullOrWhiteSpace($input)) {
        return $Default
    }
    return $input
}

function Test-PathAndCreate {
    param(
        [string]$Path,
        [string]$Description
    )
    
    if (Test-Path $Path -PathType Container) {
        Write-Success "Path exists: $Path"
        return $true
    } else {
        Write-Warning "Path does not exist: $Path"
        $choice = Read-Host "  Would you like to create it? (y/n)"
        if ($choice -match '^[Yy]$') {
            try {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
                Write-Success "Created directory: $Path"
                return $true
            } catch {
                Write-Error "Failed to create directory. Please check permissions."
                return $false
            }
        } else {
            Write-Error "Path is required. Please create it manually and re-run setup."
            return $false
        }
    }
}

function Load-ExistingEnv {
    param([string]$FilePath)
    
    $envVars = @{}
    
    if (Test-Path $FilePath) {
        Write-Info "Found existing .env file. Loading current values as defaults..."
        
        Get-Content $FilePath | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                $envVars[$key] = $value
            }
        }
    }
    
    return $envVars
}

# =============================================================================
# Main Setup
# =============================================================================

Write-Header

# =============================================================================
# Setup Type Selection
# =============================================================================

Write-Section "Setup Type"

Write-Host "  Choose how you want to deploy Simplarr:"
Write-Host ""
Write-Host "    [1] Unified Setup" -ForegroundColor Cyan
Write-Host "        All services on a single machine"
Write-Host "        Best for: Dedicated servers, NAS with enough resources"
Write-Host ""
Write-Host "    [2] Split Setup" -ForegroundColor Cyan
Write-Host "        Services split between NAS and a Pi/Server"
Write-Host "        NAS runs:     Plex + qBittorrent"
Write-Host "        Pi/Server:    *arr apps + Nginx + Homepage"
Write-Host "        Best for: Lower-power NAS, offloading API-heavy services"
Write-Host ""

$setupChoice = ""
while ($setupChoice -notin @("1", "2")) {
    $setupChoice = Read-Host "  Select setup type (1 or 2)"
}

$SETUP_TYPE = if ($setupChoice -eq "1") { "unified" } else { "split" }
$SPLIT_DEVICE = ""
$NAS_IP = ""

if ($SETUP_TYPE -eq "split") {
    Write-Host ""
    Write-Host "  Which device are you configuring now?" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    [1] NAS       - Will run Plex + qBittorrent"
    Write-Host "    [2] Pi/Server - Will run Radarr, Sonarr, Prowlarr, Overseerr, Nginx"
    Write-Host ""
    
    $deviceChoice = ""
    while ($deviceChoice -notin @("1", "2")) {
        $deviceChoice = Read-Host "  Select device (1 or 2)"
    }
    
    $SPLIT_DEVICE = if ($deviceChoice -eq "1") { "nas" } else { "pi" }
    Write-Success "Configuring for split setup: $($SPLIT_DEVICE.ToUpper())"
} else {
    Write-Success "Configuring for unified setup"
}

# Initialize variables
$existingEnv = @{}

# Check for existing .env
if (Test-Path $EnvFile) {
    Write-Host "An existing .env file was found." -ForegroundColor Yellow
    $updateChoice = Read-Host "Would you like to update it? (y/n)"
    if ($updateChoice -notmatch '^[Yy]$') {
        Write-Host "Setup cancelled. Your existing .env file was not modified." -ForegroundColor Cyan
        exit 0
    }
    $existingEnv = Load-ExistingEnv -FilePath $EnvFile
    Write-Host ""
}

# =============================================================================
# PUID Configuration
# =============================================================================

Write-Section "User ID (PUID)"

Write-Host "  The PUID is used to run containers as your user to avoid permission issues."
Write-Host ""
Write-Host "  " -NoNewline
Write-Host "Windows Note: " -ForegroundColor Yellow -NoNewline
Write-Host "On Windows/Docker Desktop, PUID/PGID are typically set to 1000."
Write-Hint "On Linux/Mac, run 'id -u' in terminal to find your user ID"

$defaultPuid = if ($existingEnv['PUID']) { $existingEnv['PUID'] } else { "1000" }

Write-Host ""
$PUID = Read-UserInput -Prompt "Enter PUID" -Default $defaultPuid
Write-Success "PUID set to: $PUID"

# =============================================================================
# PGID Configuration
# =============================================================================

Write-Section "Group ID (PGID)"

Write-Host "  The PGID is used to run containers with your group permissions."
Write-Host ""
Write-Host "  " -NoNewline
Write-Host "Windows Note: " -ForegroundColor Yellow -NoNewline
Write-Host "On Windows/Docker Desktop, PUID/PGID are typically set to 1000."
Write-Hint "On Linux/Mac, run 'id -g' in terminal to find your group ID"

$defaultPgid = if ($existingEnv['PGID']) { $existingEnv['PGID'] } else { "1000" }

Write-Host ""
$PGID = Read-UserInput -Prompt "Enter PGID" -Default $defaultPgid
Write-Success "PGID set to: $PGID"

# =============================================================================
# Timezone Configuration
# =============================================================================

Write-Section "Timezone (TZ)"

Write-Host "  Set your timezone for proper scheduling and log timestamps."
Write-Host ""
Write-Host "  Common examples:" -ForegroundColor Cyan
Write-Host "    * America/New_York     * America/Los_Angeles"
Write-Host "    * America/Chicago      * America/Denver"
Write-Host "    * Europe/London        * Europe/Paris"
Write-Host "    * Australia/Sydney     * Asia/Tokyo"
Write-Hint "Full list: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"

$defaultTz = if ($existingEnv['TZ']) { $existingEnv['TZ'] } else { "America/New_York" }

Write-Host ""
$TZ = Read-UserInput -Prompt "Enter Timezone" -Default $defaultTz
Write-Success "Timezone set to: $TZ"

# =============================================================================
# Docker Config Path
# =============================================================================

Write-Section "Docker Config Path (DOCKER_CONFIG)"

Write-Host "  This is where all your service configurations will be stored."
Write-Host "  Each service (Plex, Sonarr, Radarr, etc.) will have its own subfolder."
Write-Hint "Example: C:\Docker\Config or D:\DockerData\config"

$defaultConfig = if ($existingEnv['DOCKER_CONFIG']) { $existingEnv['DOCKER_CONFIG'] } else { "" }

Write-Host ""
$DOCKER_CONFIG = Read-UserInput -Prompt "Enter config path" -Default $defaultConfig

if ([string]::IsNullOrWhiteSpace($DOCKER_CONFIG)) {
    Write-Error "Config path is required!"
    exit 1
}

if (-not (Test-PathAndCreate -Path $DOCKER_CONFIG -Description "config")) {
    exit 1
}

# =============================================================================
# Docker Media Path
# =============================================================================

Write-Section "Docker Media Path (DOCKER_MEDIA)"

Write-Host "  This is your main media library location."
Write-Host "  It should contain (or will contain) these subdirectories:"
Write-Host "    movies/    " -ForegroundColor Cyan -NoNewline
Write-Host "- Your movie collection"
Write-Host "    tv/        " -ForegroundColor Cyan -NoNewline
Write-Host "- Your TV show collection"
Write-Host "    downloads/ " -ForegroundColor Cyan -NoNewline
Write-Host "- Download client output"
Write-Hint "Example: D:\Media or \\NAS\Media"

$defaultMedia = if ($existingEnv['DOCKER_MEDIA']) { $existingEnv['DOCKER_MEDIA'] } else { "" }

Write-Host ""
$DOCKER_MEDIA = Read-UserInput -Prompt "Enter media path" -Default $defaultMedia

if ([string]::IsNullOrWhiteSpace($DOCKER_MEDIA)) {
    Write-Error "Media path is required!"
    exit 1
}

if (-not (Test-PathAndCreate -Path $DOCKER_MEDIA -Description "media")) {
    exit 1
}

# Check/create subdirectories
Write-Host ""
Write-Info "Checking media subdirectories..."

foreach ($subdir in @("movies", "tv", "downloads")) {
    $subpath = Join-Path $DOCKER_MEDIA $subdir
    if (Test-Path $subpath -PathType Container) {
        Write-Success "Found: $subpath"
    } else {
        $createSub = Read-Host "  Create $subdir directory? (y/n)"
        if ($createSub -match '^[Yy]$') {
            try {
                New-Item -ItemType Directory -Path $subpath -Force | Out-Null
                Write-Success "Created: $subpath"
            } catch {
                Write-Warning "Could not create: $subpath"
            }
        }
    }
}

# =============================================================================
# Plex Claim Token
# =============================================================================

Write-Section "Plex Claim Token (PLEX_CLAIM)"

Write-Host "  A claim token links this Plex server to your Plex account."
Write-Host ""
Write-Host "  IMPORTANT: Claim tokens expire in 4 minutes!" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Steps:" -ForegroundColor Cyan
Write-Host "    1. Go to: " -NoNewline
Write-Host "https://plex.tv/claim" -ForegroundColor White
Write-Host "    2. Sign in to your Plex account"
Write-Host "    3. Copy the token (starts with 'claim-')"
Write-Host "    4. Paste it here immediately"
Write-Host ""
Write-Hint "You can leave this blank and add it later to .env before first run"

$defaultClaim = if ($existingEnv['PLEX_CLAIM']) { $existingEnv['PLEX_CLAIM'] } else { "" }

Write-Host ""
$PLEX_CLAIM = Read-UserInput -Prompt "Enter Plex Claim Token (or press Enter to skip)" -Default $defaultClaim

if (-not [string]::IsNullOrWhiteSpace($PLEX_CLAIM)) {
    if ($PLEX_CLAIM.StartsWith("claim-")) {
        Write-Success "Plex claim token set"
    } else {
        Write-Warning "Token doesn't start with 'claim-' - please verify it's correct"
    }
} else {
    Write-Warning "No claim token set. Remember to add it before starting Plex!"
}

# =============================================================================
# NAS IP Configuration (Split Setup Only)
# =============================================================================

if ($SETUP_TYPE -eq "split" -and $SPLIT_DEVICE -eq "pi") {
    Write-Section "NAS IP Address"
    
    Write-Host "  Enter the IP address of your NAS."
    Write-Host "  This is needed so the reverse proxy can reach Plex and qBittorrent."
    Write-Hint "Example: 192.168.1.100 or 10.0.0.50"
    
    Write-Host ""
    while ($true) {
        $NAS_IP = Read-Host "  Enter NAS IP address"
        # Basic IP validation
        if ($NAS_IP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            Write-Success "NAS IP set to: $NAS_IP"
            break
        } else {
            Write-Error "Please enter a valid IP address (e.g., 192.168.1.100)"
        }
    }
}

# =============================================================================
# Summary
# =============================================================================

Write-Section "Configuration Summary"

Write-Host ""
Write-Host "  Setup Type:    " -NoNewline
$setupDisplay = if ($SPLIT_DEVICE) { "$SETUP_TYPE ($SPLIT_DEVICE)" } else { $SETUP_TYPE }
Write-Host $setupDisplay -ForegroundColor White
Write-Host "  PUID:          " -NoNewline
Write-Host $PUID -ForegroundColor White
Write-Host "  PGID:          " -NoNewline
Write-Host $PGID -ForegroundColor White
Write-Host "  TZ:            " -NoNewline
Write-Host $TZ -ForegroundColor White
Write-Host "  DOCKER_CONFIG: " -NoNewline
Write-Host $DOCKER_CONFIG -ForegroundColor White
Write-Host "  DOCKER_MEDIA:  " -NoNewline
Write-Host $DOCKER_MEDIA -ForegroundColor White
Write-Host "  PLEX_CLAIM:    " -NoNewline
if ([string]::IsNullOrWhiteSpace($PLEX_CLAIM)) {
    Write-Host "<not set>" -ForegroundColor DarkGray
} else {
    Write-Host $PLEX_CLAIM -ForegroundColor White
}
if (-not [string]::IsNullOrWhiteSpace($NAS_IP)) {
    Write-Host "  NAS_IP:        " -NoNewline
    Write-Host $NAS_IP -ForegroundColor White
}
Write-Host ""

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
$saveChoice = Read-Host "  Save this configuration to .env? (y/n)"

if ($saveChoice -notmatch '^[Yy]$') {
    Write-Host "Setup cancelled. No changes were made." -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# Write .env File
# =============================================================================

# Backup existing file
if (Test-Path $EnvFile) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = "$EnvFile.backup.$timestamp"
    Copy-Item $EnvFile $backupFile
    Write-Info "Backed up existing .env to: $(Split-Path -Leaf $backupFile)"
}

# Write new .env file
$envContent = @"
# =============================================================================
# Simplarr - Environment Configuration
# Generated by setup.ps1 on $(Get-Date)
# =============================================================================

# User/Group IDs - On Windows/Docker Desktop, 1000 is typically used
# On Linux/Mac, run 'id -u' and 'id -g' to find yours
PUID=$PUID
PGID=$PGID

# Timezone - https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
TZ=$TZ

# Docker configuration path - where service configs are stored
DOCKER_CONFIG=$DOCKER_CONFIG

# Media library path - should contain movies/, tv/, downloads/
DOCKER_MEDIA=$DOCKER_MEDIA

# Plex claim token - get from https://plex.tv/claim (expires in 4 minutes!)
PLEX_CLAIM=$PLEX_CLAIM
"@

$envContent | Out-File -FilePath $EnvFile -Encoding utf8 -Force

Write-Host ""
Write-Success "Configuration saved to: $EnvFile"

# =============================================================================
# Create Service Config Directories & Deploy Templates
# =============================================================================

Write-Section "Setting Up Service Configurations"

# Create config subdirectories
$services = @("plex", "radarr", "sonarr", "prowlarr", "qbittorrent", "overseerr", "tautulli", "nginx", "homepage")
foreach ($service in $services) {
    $servicePath = Join-Path $DOCKER_CONFIG $service
    if (-not (Test-Path $servicePath -PathType Container)) {
        New-Item -ItemType Directory -Path $servicePath -Force | Out-Null
        Write-Success "Created: $servicePath"
    }
}

# Create qBittorrent subdirectory structure
$qbitSubDir = Join-Path $DOCKER_CONFIG "qbittorrent\qBittorrent"
New-Item -ItemType Directory -Path $qbitSubDir -Force -ErrorAction SilentlyContinue | Out-Null

# Deploy qBittorrent pre-configured template
$qbitTemplate = Join-Path $ScriptDir "templates\qBittorrent\qBittorrent.conf"
$qbitConfig = Join-Path $qbitSubDir "qBittorrent.conf"

if (Test-Path $qbitTemplate) {
    if (-not (Test-Path $qbitConfig)) {
        Copy-Item $qbitTemplate $qbitConfig -Force
        Write-Success "Deployed qBittorrent pre-configured template"
        Write-Info "  -> Auto-add trackers: ENABLED (public tracker list)"
        Write-Info "  -> Download path: /downloads"
        Write-Info "  -> Incomplete path: /downloads/incomplete"
        Write-Info "  -> Max active downloads: 50"
        Write-Info "  -> DHT/PeX/LSD: ENABLED"
    } else {
        Write-Warning "qBittorrent config already exists, skipping template deployment"
        Write-Hint "Delete $qbitConfig to use the template on next setup"
    }
} else {
    Write-Warning "qBittorrent template not found at: $qbitTemplate"
}

# Create incomplete downloads directory
$incompletePath = Join-Path $DOCKER_MEDIA "downloads\incomplete"
New-Item -ItemType Directory -Path $incompletePath -Force -ErrorAction SilentlyContinue | Out-Null
Write-Success "Created incomplete downloads directory"

# =============================================================================
# Update Nginx Config (Split Setup Only)
# =============================================================================

if ($SETUP_TYPE -eq "split" -and $SPLIT_DEVICE -eq "pi" -and -not [string]::IsNullOrWhiteSpace($NAS_IP)) {
    $splitConf = Join-Path $ScriptDir "nginx\split.conf"
    if (Test-Path $splitConf) {
        # Replace YOUR_NAS_IP placeholder with actual IP
        $content = Get-Content $splitConf -Raw
        $content = $content -replace 'YOUR_NAS_IP', $NAS_IP
        $content | Out-File -FilePath $splitConf -Encoding utf8 -Force -NoNewline
        Write-Success "Updated nginx/split.conf with NAS IP: $NAS_IP"
    } else {
        Write-Warning "nginx/split.conf not found - you may need to update it manually"
    }
}

# =============================================================================
# Next Steps
# =============================================================================

Write-Section "Next Steps"

Write-Host ""

if ($SETUP_TYPE -eq "unified") {
    # Unified setup instructions
    Write-Host "  1. " -ForegroundColor Green -NoNewline
    Write-Host "Review your .env file: " -NoNewline
    Write-Host "Get-Content .env" -ForegroundColor White
    Write-Host "  2. " -ForegroundColor Green -NoNewline
    Write-Host "Start your stack: " -NoNewline
    Write-Host "docker compose -f docker-compose-unified.yml up -d" -ForegroundColor White
    Write-Host "  3. " -ForegroundColor Green -NoNewline
    Write-Host "Wait for containers: " -NoNewline
    Write-Host "docker compose -f docker-compose-unified.yml ps" -ForegroundColor White
    Write-Host "  4. " -ForegroundColor Green -NoNewline
    Write-Host "Run auto-configure: " -NoNewline
    Write-Host ".\configure.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "  Access your services:" -ForegroundColor Cyan
    Write-Host "       * Plex:        http://localhost:32400/web"
    Write-Host "       * Radarr:      http://localhost:7878"
    Write-Host "       * Sonarr:      http://localhost:8989"
    Write-Host "       * Prowlarr:    http://localhost:9696"
    Write-Host "       * qBittorrent: http://localhost:8080"
    Write-Host "       * Overseerr:   http://localhost:5055"
    Write-Host ""
    Write-Host "  qBittorrent Note:" -ForegroundColor Yellow
    Write-Host "       Check container logs for initial password:"
    Write-Host "       docker logs qbittorrent 2>&1 | Select-String password" -ForegroundColor White
}
elseif ($SETUP_TYPE -eq "split" -and $SPLIT_DEVICE -eq "nas") {
    # Split NAS setup instructions
    Write-Host "  1. " -ForegroundColor Green -NoNewline
    Write-Host "Review your .env file: " -NoNewline
    Write-Host "Get-Content .env" -ForegroundColor White
    Write-Host "  2. " -ForegroundColor Green -NoNewline
    Write-Host "Start NAS services: " -NoNewline
    Write-Host "docker compose -f docker-compose-nas.yml up -d" -ForegroundColor White
    Write-Host "  3. " -ForegroundColor Green -NoNewline
    Write-Host "Wait for containers: " -NoNewline
    Write-Host "docker compose -f docker-compose-nas.yml ps" -ForegroundColor White
    Write-Host ""
    Write-Host "  NAS Services (local access):" -ForegroundColor Cyan
    Write-Host "       * Plex:        http://localhost:32400/web"
    Write-Host "       * qBittorrent: http://localhost:8080"
    Write-Host ""
    Write-Host "  qBittorrent Note:" -ForegroundColor Yellow
    Write-Host "       Check container logs for initial password:"
    Write-Host "       docker logs qbittorrent 2>&1 | Select-String password" -ForegroundColor White
    Write-Host ""
    Write-Host "  Next:" -ForegroundColor Yellow -NoNewline
    Write-Host " Run setup.sh or setup.ps1 on your Pi/Server to set up the remaining services."
}
elseif ($SETUP_TYPE -eq "split" -and $SPLIT_DEVICE -eq "pi") {
    # Split Pi/Server setup instructions
    Write-Host "  1. " -ForegroundColor Green -NoNewline
    Write-Host "Review your .env file: " -NoNewline
    Write-Host "Get-Content .env" -ForegroundColor White
    Write-Host "  2. " -ForegroundColor Green -NoNewline
    Write-Host "Start Pi/Server services: " -NoNewline
    Write-Host "docker compose -f docker-compose-pi.yml up -d" -ForegroundColor White
    Write-Host "  3. " -ForegroundColor Green -NoNewline
    Write-Host "Wait for containers: " -NoNewline
    Write-Host "docker compose -f docker-compose-pi.yml ps" -ForegroundColor White
    Write-Host "  4. " -ForegroundColor Green -NoNewline
    Write-Host "Run auto-configure: " -NoNewline
    Write-Host ".\configure.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "  Pi/Server Services (via Nginx at :80):" -ForegroundColor Cyan
    Write-Host "       * Homepage:    http://localhost/"
    Write-Host "       * Plex:        http://localhost/plex  -> NAS ($NAS_IP)"
    Write-Host "       * Radarr:      http://localhost/radarr"
    Write-Host "       * Sonarr:      http://localhost/sonarr"
    Write-Host "       * Prowlarr:    http://localhost/prowlarr"
    Write-Host "       * qBittorrent: http://localhost/qbittorrent -> NAS ($NAS_IP)"
    Write-Host "       * Overseerr:   http://localhost/overseerr"
    Write-Host ""
    Write-Host "  Note:" -ForegroundColor Yellow -NoNewline
    Write-Host " Make sure your NAS services are running!"
    Write-Host "  Note:" -ForegroundColor Yellow -NoNewline
    Write-Host " nginx/split.conf has been configured with NAS IP: $NAS_IP"
}

Write-Host ""
Write-Host "Setup complete! Happy streaming! " -ForegroundColor Green -NoNewline
Write-Host "[Movie Icon]" -ForegroundColor Cyan
Write-Host ""
