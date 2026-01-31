# =============================================================================
# Simplarr Configuration Script (PowerShell)
# =============================================================================
# This script connects all your *arr services together using their APIs.
# Run this AFTER docker-compose up -d and all services are healthy.
#
# What it does:
# 1. Waits for all services to be ready
# 2. Retrieves API keys from each service
# 3. Adds qBittorrent as download client to Radarr/Sonarr
# 4. Connects Prowlarr to Radarr/Sonarr for indexer sync
# 5. Adds popular public indexers to Prowlarr
# 6. Configures root folders in Radarr/Sonarr
# =============================================================================

param(
    [string]$RadarrUrl = "http://localhost:7878",
    [string]$SonarrUrl = "http://localhost:8989",
    [string]$ProwlarrUrl = "http://localhost:9696",
    [string]$QBittorrentUrl = "http://localhost:8080",
    [string]$ConfigDir = ".\configs"
)

# Internal Docker network names
$RadarrHost = "radarr"
$SonarrHost = "sonarr"
$ProwlarrHost = "prowlarr"
$QBittorrentHost = "qbittorrent"

# Paths inside containers
$MoviesPath = "/movies"
$TvPath = "/tv"
$DownloadsPath = "/downloads"

# qBittorrent credentials
# Username defaults to admin, password retrieved from logs
$QbUsername = "admin"
$QbPassword = $null  # Will be retrieved from docker logs

# =============================================================================
# Helper Functions
# =============================================================================

function Get-QBittorrentPassword {
    param([string]$ContainerName = "qbittorrent")
    
    Write-Info "Retrieving qBittorrent temporary password from logs..."
    
    $logs = docker logs $ContainerName 2>&1 | Out-String
    if ($logs -match "temporary password[^:]*:\s*(\S+)") {
        $password = $Matches[1].Trim()
        Write-Success "Retrieved qBittorrent password"
        return $password
    }
    
    Write-Warning "Could not retrieve qBittorrent password from logs"
    Write-Info "You can check manually: docker logs qbittorrent 2>&1 | Select-String password"
    return $null
}

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 75) -ForegroundColor Blue
    Write-Host "  $Text" -ForegroundColor Blue
    Write-Host ("=" * 75) -ForegroundColor Blue
    Write-Host ""
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Success {
    param([string]$Message)
    Write-Host "[✓] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[!] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Error {
    param([string]$Message)
    Write-Host "[✗] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Wait-ForService {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Endpoint,
        [int]$MaxAttempts = 30
    )
    
    Write-Info "Waiting for $Name to be ready..."
    
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "$Url$Endpoint" -Method Get -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($response.StatusCode -in @(200, 401, 302)) {
                Write-Success "$Name is ready"
                return $true
            }
        }
        catch {
            Write-Host "." -NoNewline
        }
        Start-Sleep -Seconds 2
    }
    
    Write-Host ""
    Write-Error "$Name is not responding after $MaxAttempts attempts"
    return $false
}

function Get-ArrApiKey {
    param(
        [string]$Name,
        [string]$ConfigPath
    )
    
    if (Test-Path $ConfigPath) {
        $content = Get-Content $ConfigPath -Raw
        if ($content -match '<ApiKey>([^<]+)</ApiKey>') {
            return $matches[1]
        }
    }
    
    Write-Error "Could not get API key for $Name from $ConfigPath"
    return $null
}

# =============================================================================
# Service Configuration Functions
# =============================================================================

function Add-QBittorrentToRadarr {
    param([string]$ApiKey)
    
    Write-Info "Adding qBittorrent to Radarr..."
    
    $body = @{
        enable = $true
        protocol = "torrent"
        priority = 1
        removeCompletedDownloads = $true
        removeFailedDownloads = $true
        name = "qBittorrent"
        fields = @(
            @{ name = "host"; value = $QBittorrentHost }
            @{ name = "port"; value = 8080 }
            @{ name = "useSsl"; value = $false }
            @{ name = "urlBase"; value = "" }
            @{ name = "username"; value = $QbUsername }
            @{ name = "password"; value = $QbPassword }
            @{ name = "movieCategory"; value = "radarr" }
            @{ name = "movieImportedCategory"; value = "" }
            @{ name = "recentMoviePriority"; value = 0 }
            @{ name = "olderMoviePriority"; value = 0 }
            @{ name = "initialState"; value = 0 }
            @{ name = "sequentialOrder"; value = $false }
            @{ name = "firstAndLast"; value = $false }
        )
        implementationName = "qBittorrent"
        implementation = "QBittorrent"
        configContract = "QBittorrentSettings"
        tags = @()
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "$RadarrUrl/api/v3/downloadclient" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "qBittorrent added to Radarr"
        return $true
    }
    catch {
        Write-Warning "qBittorrent may already exist in Radarr or failed to add: $($_.Exception.Message)"
        return $false
    }
}

function Add-QBittorrentToSonarr {
    param([string]$ApiKey)
    
    Write-Info "Adding qBittorrent to Sonarr..."
    
    $body = @{
        enable = $true
        protocol = "torrent"
        priority = 1
        removeCompletedDownloads = $true
        removeFailedDownloads = $true
        name = "qBittorrent"
        fields = @(
            @{ name = "host"; value = $QBittorrentHost }
            @{ name = "port"; value = 8080 }
            @{ name = "useSsl"; value = $false }
            @{ name = "urlBase"; value = "" }
            @{ name = "username"; value = $QbUsername }
            @{ name = "password"; value = $QbPassword }
            @{ name = "tvCategory"; value = "sonarr" }
            @{ name = "tvImportedCategory"; value = "" }
            @{ name = "recentTvPriority"; value = 0 }
            @{ name = "olderTvPriority"; value = 0 }
            @{ name = "initialState"; value = 0 }
            @{ name = "sequentialOrder"; value = $false }
            @{ name = "firstAndLast"; value = $false }
        )
        implementationName = "qBittorrent"
        implementation = "QBittorrent"
        configContract = "QBittorrentSettings"
        tags = @()
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "$SonarrUrl/api/v3/downloadclient" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "qBittorrent added to Sonarr"
        return $true
    }
    catch {
        Write-Warning "qBittorrent may already exist in Sonarr or failed to add: $($_.Exception.Message)"
        return $false
    }
}

function Add-RadarrToProwlarr {
    param(
        [string]$ProwlarrKey,
        [string]$RadarrKey
    )
    
    Write-Info "Adding Radarr to Prowlarr..."
    
    $body = @{
        syncLevel = "fullSync"
        name = "Radarr"
        fields = @(
            @{ name = "prowlarrUrl"; value = "http://${ProwlarrHost}:9696" }
            @{ name = "baseUrl"; value = "http://${RadarrHost}:7878" }
            @{ name = "apiKey"; value = $RadarrKey }
            @{ name = "syncCategories"; value = @(2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080) }
        )
        implementationName = "Radarr"
        implementation = "Radarr"
        configContract = "RadarrSettings"
        tags = @()
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "$ProwlarrUrl/api/v1/applications" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ProwlarrKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Radarr added to Prowlarr"
        return $true
    }
    catch {
        Write-Warning "Radarr may already exist in Prowlarr or failed to add: $($_.Exception.Message)"
        return $false
    }
}

function Add-SonarrToProwlarr {
    param(
        [string]$ProwlarrKey,
        [string]$SonarrKey
    )
    
    Write-Info "Adding Sonarr to Prowlarr..."
    
    $body = @{
        syncLevel = "fullSync"
        name = "Sonarr"
        fields = @(
            @{ name = "prowlarrUrl"; value = "http://${ProwlarrHost}:9696" }
            @{ name = "baseUrl"; value = "http://${SonarrHost}:8989" }
            @{ name = "apiKey"; value = $SonarrKey }
            @{ name = "syncCategories"; value = @(5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080) }
        )
        implementationName = "Sonarr"
        implementation = "Sonarr"
        configContract = "SonarrSettings"
        tags = @()
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "$ProwlarrUrl/api/v1/applications" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ProwlarrKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Sonarr added to Prowlarr"
        return $true
    }
    catch {
        Write-Warning "Sonarr may already exist in Prowlarr or failed to add: $($_.Exception.Message)"
        return $false
    }
}

function Add-RadarrRootFolder {
    param([string]$ApiKey)
    
    Write-Info "Adding root folder to Radarr..."
    
    $body = @{ path = $MoviesPath } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$RadarrUrl/api/v3/rootfolder" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Root folder added to Radarr: $MoviesPath"
        return $true
    }
    catch {
        Write-Warning "Root folder may already exist in Radarr"
        return $false
    }
}

function Add-SonarrRootFolder {
    param([string]$ApiKey)
    
    Write-Info "Adding root folder to Sonarr..."
    
    $body = @{ path = $TvPath } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$SonarrUrl/api/v3/rootfolder" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Root folder added to Sonarr: $TvPath"
        return $true
    }
    catch {
        Write-Warning "Root folder may already exist in Sonarr"
        return $false
    }
}

function Add-PublicIndexer {
    param(
        [string]$ApiKey,
        [string]$Name,
        [string]$BaseUrl,
        [string]$DefinitionName
    )
    
    $body = @{
        enable = $true
        redirect = $false
        name = $Name
        fields = @(
            @{ name = "baseUrl"; value = $BaseUrl }
            @{ name = "baseSettings.limitsUnit"; value = 0 }
        )
        implementationName = $Name
        implementation = "Cardigann"
        configContract = "CardigannSettings"
        definitionName = $DefinitionName
        tags = @()
        priority = 25
        appProfileId = 1
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "$ProwlarrUrl/api/v1/indexer" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Added $Name"
        return $true
    }
    catch {
        Write-Warning "$Name may already exist"
        return $false
    }
}

function Add-PublicIndexers {
    param([string]$ApiKey)
    
    Write-Info "Adding public indexers to Prowlarr..."
    Write-Info "Note: Some indexers may fail due to geo-blocking or Cloudflare protection"
    
    # NOTE: 1337x and EZTV removed - often blocked (Cloudflare, geo-blocking in AU/UK)
    # Add them manually in Prowlarr if they work in your region
    $indexers = @(
        @{ Name = "YTS"; Url = "https://yts.mx"; Definition = "yts" }
        @{ Name = "The Pirate Bay"; Url = "https://thepiratebay.org"; Definition = "thepiratebay" }
        @{ Name = "TorrentGalaxy"; Url = "https://torrentgalaxy.to"; Definition = "torrentgalaxy" }
        @{ Name = "Nyaa.si"; Url = "https://nyaa.si"; Definition = "nyaasi" }
        @{ Name = "LimeTorrents"; Url = "https://www.limetorrents.lol"; Definition = "limetorrents" }
    )
    
    foreach ($indexer in $indexers) {
        Add-PublicIndexer -ApiKey $ApiKey -Name $indexer.Name -BaseUrl $indexer.Url -DefinitionName $indexer.Definition
    }
}

function Sync-ProwlarrIndexers {
    param([string]$ApiKey)
    
    Write-Info "Triggering Prowlarr indexer sync..."
    
    $body = @{ name = "ApplicationIndexerSync" } | ConvertTo-Json
    
    try {
        Invoke-RestMethod -Uri "$ProwlarrUrl/api/v1/command" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction SilentlyContinue | Out-Null
        
        Write-Success "Indexer sync triggered"
    }
    catch {
        Write-Warning "Could not trigger sync"
    }
}

# =============================================================================
# Main Execution
# =============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Blue
Write-Host "║                    Simplarr Configuration Script                       ║" -ForegroundColor Blue
Write-Host "║                                                                        ║" -ForegroundColor Blue
Write-Host "║  This script will wire up your *arr services automatically.            ║" -ForegroundColor Blue
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Blue
Write-Host ""

# Check if we should use local config files or wait for services
$radarrConfig = Join-Path $ConfigDir "radarr\config.xml"
$sonarrConfig = Join-Path $ConfigDir "sonarr\config.xml"
$prowlarrConfig = Join-Path $ConfigDir "prowlarr\config.xml"

if (Test-Path $radarrConfig) {
    Write-Info "Found local config files, extracting API keys..."
    $RadarrApiKey = Get-ArrApiKey -Name "Radarr" -ConfigPath $radarrConfig
    $SonarrApiKey = Get-ArrApiKey -Name "Sonarr" -ConfigPath $sonarrConfig
    $ProwlarrApiKey = Get-ArrApiKey -Name "Prowlarr" -ConfigPath $prowlarrConfig
}
else {
    Write-Info "Waiting for services to generate configs..."
    
    Wait-ForService -Name "Radarr" -Url $RadarrUrl -Endpoint "/api/v3/system/status"
    Wait-ForService -Name "Sonarr" -Url $SonarrUrl -Endpoint "/api/v3/system/status"
    Wait-ForService -Name "Prowlarr" -Url $ProwlarrUrl -Endpoint "/api/v1/system/status"
    Wait-ForService -Name "qBittorrent" -Url $QBittorrentUrl -Endpoint "/"
    
    Write-Host ""
    Write-Warning "Services are running but API keys need to be provided."
    Write-Host ""
    $RadarrApiKey = Read-Host "Enter Radarr API key (from Settings > General)"
    $SonarrApiKey = Read-Host "Enter Sonarr API key (from Settings > General)"
    $ProwlarrApiKey = Read-Host "Enter Prowlarr API key (from Settings > General)"
}

Write-Header "Configuring Download Clients"

# Get qBittorrent password from logs if not provided
$QbPassword = Get-QBittorrentPassword -ContainerName "qbittorrent"
if (-not $QbPassword) {
    Write-Warning "Could not retrieve qBittorrent password automatically."
    Write-Info "Please check: docker logs qbittorrent 2>&1 | Select-String password"
    $QbPassword = Read-Host "Enter qBittorrent WebUI password"
}

Add-QBittorrentToRadarr -ApiKey $RadarrApiKey
Add-QBittorrentToSonarr -ApiKey $SonarrApiKey

Write-Header "Configuring Root Folders"
Add-RadarrRootFolder -ApiKey $RadarrApiKey
Add-SonarrRootFolder -ApiKey $SonarrApiKey

Write-Header "Configuring Prowlarr Connections"
Add-RadarrToProwlarr -ProwlarrKey $ProwlarrApiKey -RadarrKey $RadarrApiKey
Add-SonarrToProwlarr -ProwlarrKey $ProwlarrApiKey -SonarrKey $SonarrApiKey

Write-Header "Adding Public Indexers"
Add-PublicIndexers -ApiKey $ProwlarrApiKey

Write-Info "Waiting 5 seconds for indexers to be added..."
Start-Sleep -Seconds 5

Sync-ProwlarrIndexers -ApiKey $ProwlarrApiKey

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    Configuration Complete! 🎉                          ║" -ForegroundColor Green
Write-Host "╠═══════════════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║                                                                        ║" -ForegroundColor Green
Write-Host "║  Your services are now connected:                                      ║" -ForegroundColor Green
Write-Host "║                                                                        ║" -ForegroundColor Green
Write-Host "║  ✓ qBittorrent → Radarr (download client)                              ║" -ForegroundColor Green
Write-Host "║  ✓ qBittorrent → Sonarr (download client)                              ║" -ForegroundColor Green
Write-Host "║  ✓ Prowlarr → Radarr (indexer sync)                                    ║" -ForegroundColor Green
Write-Host "║  ✓ Prowlarr → Sonarr (indexer sync)                                    ║" -ForegroundColor Green
Write-Host "║  ✓ Public indexers added to Prowlarr                                   ║" -ForegroundColor Green
Write-Host "║                                                                        ║" -ForegroundColor Green
Write-Host "║  Next Steps:                                                           ║" -ForegroundColor Green
Write-Host "║  1. Open Radarr/Sonarr and verify Settings > Download Clients          ║" -ForegroundColor Green
Write-Host "║  2. Check Prowlarr > Settings > Apps for sync status                   ║" -ForegroundColor Green
Write-Host "║  3. Add a movie in Radarr or show in Sonarr to test                    ║" -ForegroundColor Green
Write-Host "║  4. (Optional) Add more indexers in Prowlarr                           ║" -ForegroundColor Green
Write-Host "║                                                                        ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
