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

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'This interactive configuration script intentionally uses Write-Host for colored console output. Write-Output cannot produce the colored terminal UI required for the user experience.'
)]
param(
    [int]$RadarrPort      = $(if ($env:RADARR_PORT)      { [int]$env:RADARR_PORT }      else { 7878 }),
    [int]$SonarrPort      = $(if ($env:SONARR_PORT)      { [int]$env:SONARR_PORT }      else { 8989 }),
    [int]$ProwlarrPort    = $(if ($env:PROWLARR_PORT)    { [int]$env:PROWLARR_PORT }    else { 9696 }),
    [int]$QBittorrentPort = $(if ($env:QBITTORRENT_PORT) { [int]$env:QBITTORRENT_PORT } else { 8080 }),
    [int]$OverseerrPort   = $(if ($env:OVERSEERR_PORT)   { [int]$env:OVERSEERR_PORT }   else { 5055 }),
    [string]$RadarrUrl      = "http://localhost:$RadarrPort",
    [string]$SonarrUrl      = "http://localhost:$SonarrPort",
    [string]$ProwlarrUrl    = "http://localhost:$ProwlarrPort",
    [string]$QBittorrentUrl = "http://localhost:$QBittorrentPort",
    [string]$OverseerrUrl   = "http://localhost:$OverseerrPort",
    [string]$ConfigDir      = ".\configs",
    [string]$QBittorrentHost = $env:QBITTORRENT_HOST
)

# Internal Docker network names
$RadarrHost = "radarr"
$SonarrHost = "sonarr"
$ProwlarrHost = "prowlarr"
$QBittorrentHost = if ([string]::IsNullOrWhiteSpace($QBittorrentHost)) { "qbittorrent" } else { $QBittorrentHost }

# Paths inside containers
$MoviesPath = "/movies"
$TvPath = "/tv"

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
    
    Write-WarningMessage "Could not retrieve qBittorrent password from logs"
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

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "[!] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "[✗] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

# Resolve the directory holding *arr / Overseerr config files. Precedence
# (highest wins):
#   1. -ConfigDir explicitly passed on the command line
#   2. $env:DOCKER_CONFIG set in the process environment
#   3. DOCKER_CONFIG=... read from the .env file next to this script — the
#      file setup.ps1 writes. docker compose reads that .env automatically for
#      ${DOCKER_CONFIG} volume substitution, but running .\configure.ps1 per
#      the readme exports nothing, so without this step the script silently
#      fell back to .\configs (issue #29, round 2).
#   4. .\configs (the param default)
function Resolve-ConfigDir {
    param(
        [string]$ConfigDir,
        # Overridable for tests; $PSScriptRoot is empty when the function is
        # loaded dynamically (e.g. via AST extraction in Pester suites).
        [string]$ScriptRoot = $PSScriptRoot
    )

    if ($ConfigDir -ne ".\configs") {
        return $ConfigDir
    }

    if ($env:DOCKER_CONFIG) {
        return $env:DOCKER_CONFIG
    }

    $envFile = Join-Path $ScriptRoot ".env"
    if (Test-Path $envFile) {
        # Last matching line wins; Get-Content strips CR/LF per line, so no
        # explicit CRLF handling is needed (unlike the bash implementation).
        $lastMatch = $null
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^DOCKER_CONFIG=(.*)$') {
                $lastMatch = $matches[1]
            }
        }
        if ($lastMatch) {
            $value = $lastMatch.Trim() -replace '^["'']|["'']$', ''
            if ($value) {
                # Relative values (e.g. "./docker") resolve against this
                # script's directory, matching how docker compose resolves
                # the same .env value against the compose project directory.
                if (-not [System.IO.Path]::IsPathRooted($value)) {
                    $value = Join-Path $ScriptRoot ($value -replace '^\./', '')
                }
                Write-Info "Loaded DOCKER_CONFIG from .env: $value"
                return $value
            }
        }
    }

    return ".\configs"
}

function Invoke-ConfigApi {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        [string]$Method = 'Get',
        [hashtable]$Headers = @{},
        [string]$Body,
        [string]$ContentType = 'application/json'
    )

    try {
        $restParams = @{
            Uri         = $Uri
            Method      = $Method
            Headers     = $Headers
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrEmpty($Body)) {
            $restParams['Body']        = $Body
            $restParams['ContentType'] = $ContentType
        }

        $response = Invoke-RestMethod @restParams

        return [PSCustomObject]@{
            Success       = $true
            StatusCode    = 200
            Body          = $response
            AlreadyExists = $false
        }
    }
    catch {
        # Extract HTTP status code from exception
        $statusCode = 0
        if ($null -ne $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        elseif ($_.Exception.Message -match 'HTTP (\d+)') {
            $statusCode = [int]$Matches[1]
        }

        # Extract response body from ErrorDetails (set by Invoke-RestMethod on non-2xx)
        $responseBody = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }

        # 409 Conflict - resource already exists (benign idempotency outcome)
        if ($statusCode -eq 409) {
            Write-Info "Resource already exists (HTTP 409)"
            return [PSCustomObject]@{
                Success       = $true
                StatusCode    = 409
                Body          = $responseBody
                AlreadyExists = $true
            }
        }

        # All other errors - hard failure; surface status code and body in warning
        Write-WarningMessage "API call failed (HTTP $statusCode): $responseBody"
        return [PSCustomObject]@{
            Success       = $false
            StatusCode    = $statusCode
            Body          = $responseBody
            AlreadyExists = $false
        }
    }
}

function Wait-ForService {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Endpoint,
        [int]$MaxAttempts = $(if ($env:WAIT_MAX_ATTEMPTS) { [int]$env:WAIT_MAX_ATTEMPTS } else { 30 }),
        [int]$SleepSeconds = $(if ($env:WAIT_RETRY_SECS) { [int]$env:WAIT_RETRY_SECS } else { 2 })
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
        Start-Sleep -Seconds $SleepSeconds
    }
    
    Write-Host ""
    Write-ErrorMessage "$Name is not responding after $MaxAttempts attempts"
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
    
    Write-ErrorMessage "Could not get API key for $Name from $ConfigPath"
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
            @{ name = "port"; value = $QBittorrentPort }
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
        $null = Invoke-RestMethod -Uri "$RadarrUrl/api/v3/downloadclient" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "qBittorrent added to Radarr"
        return $true
    }
    catch {
        Write-WarningMessage "qBittorrent may already exist in Radarr or failed to add: $($_.Exception.Message)"
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
            @{ name = "port"; value = $QBittorrentPort }
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
        $null = Invoke-RestMethod -Uri "$SonarrUrl/api/v3/downloadclient" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "qBittorrent added to Sonarr"
        return $true
    }
    catch {
        Write-WarningMessage "qBittorrent may already exist in Sonarr or failed to add: $($_.Exception.Message)"
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
            @{ name = "prowlarrUrl"; value = "http://${ProwlarrHost}:${ProwlarrPort}" }
            @{ name = "baseUrl"; value = "http://${RadarrHost}:${RadarrPort}" }
            @{ name = "apiKey"; value = $RadarrKey }
            @{ name = "syncCategories"; value = @(2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080) }
        )
        implementationName = "Radarr"
        implementation = "Radarr"
        configContract = "RadarrSettings"
        tags = @()
    } | ConvertTo-Json -Depth 10
    
    try {
        $null = Invoke-RestMethod -Uri "$ProwlarrUrl/api/v1/applications" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ProwlarrKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Radarr added to Prowlarr"
        return $true
    }
    catch {
        Write-WarningMessage "Radarr may already exist in Prowlarr or failed to add: $($_.Exception.Message)"
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
            @{ name = "prowlarrUrl"; value = "http://${ProwlarrHost}:${ProwlarrPort}" }
            @{ name = "baseUrl"; value = "http://${SonarrHost}:${SonarrPort}" }
            @{ name = "apiKey"; value = $SonarrKey }
            @{ name = "syncCategories"; value = @(5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080) }
        )
        implementationName = "Sonarr"
        implementation = "Sonarr"
        configContract = "SonarrSettings"
        tags = @()
    } | ConvertTo-Json -Depth 10
    
    try {
        $null = Invoke-RestMethod -Uri "$ProwlarrUrl/api/v1/applications" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ProwlarrKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Sonarr added to Prowlarr"
        return $true
    }
    catch {
        Write-WarningMessage "Sonarr may already exist in Prowlarr or failed to add: $($_.Exception.Message)"
        return $false
    }
}

function Add-RadarrRootFolder {
    param([string]$ApiKey)
    
    Write-Info "Adding root folder to Radarr..."
    
    $body = @{ path = $MoviesPath } | ConvertTo-Json
    
    try {
        $null = Invoke-RestMethod -Uri "$RadarrUrl/api/v3/rootfolder" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Root folder added to Radarr: $MoviesPath"
        return $true
    }
    catch {
        Write-WarningMessage "Root folder may already exist in Radarr"
        return $false
    }
}

function Add-SonarrRootFolder {
    param([string]$ApiKey)
    
    Write-Info "Adding root folder to Sonarr..."
    
    $body = @{ path = $TvPath } | ConvertTo-Json
    
    try {
        $null = Invoke-RestMethod -Uri "$SonarrUrl/api/v3/rootfolder" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Root folder added to Sonarr: $TvPath"
        return $true
    }
    catch {
        Write-WarningMessage "Root folder may already exist in Sonarr"
        return $false
    }
}

function Add-ProwlarrIndexer {
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
            @{ name = "definitionFile"; value = $DefinitionName }
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
        $null = Invoke-RestMethod -Uri "$ProwlarrUrl/api/v1/indexer" `
            -Method Post `
            -Headers @{ "X-Api-Key" = $ApiKey } `
            -ContentType "application/json" `
            -Body $body `
            -ErrorAction Stop
        
        Write-Success "Added $Name"
        return $true
    }
    catch {
        # Duplicates are pre-filtered by the caller, so a failure here is
        # almost always a real error (bad API key, validation, service not
        # ready) and must surface the HTTP status instead of being shrugged off.
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode) {
            Write-WarningMessage "Failed to add $Name (HTTP $statusCode)"
        } else {
            Write-WarningMessage "Failed to add $Name (no HTTP response: $($_.Exception.Message))"
        }
        return $false
    }
}

function Add-ProwlarrPublicIndexer {
    param([string]$ApiKey)
    
    Write-Info "Adding public indexers to Prowlarr..."
    Write-Info "Note: Some indexers may fail due to geo-blocking or Cloudflare protection"
    
    # NOTE: 1337x and EZTV removed - often blocked (Cloudflare, geo-blocking in AU/UK)
    # Add them manually in Prowlarr if they work in your region
    # NOTE: TorrentGalaxy removed - the site shut down and Prowlarr deleted the
    # definition upstream, so adding it fails with HTTP 500 for every user.
    $indexers = @(
        @{ Name = "YTS"; Url = "https://yts.mx"; Definition = "yts" }
        @{ Name = "The Pirate Bay"; Url = "https://thepiratebay.org"; Definition = "thepiratebay" }
        @{ Name = "Nyaa.si"; Url = "https://nyaa.si"; Definition = "nyaasi" }
        @{ Name = "LimeTorrents"; Url = "https://www.limetorrents.fun"; Definition = "limetorrents" }
    )

    # GET-before-POST: fetch existing indexers once to detect duplicates
    # (parity with add_public_indexers in configure.sh)
    $existingNames = @()
    try {
        $existingNames = @(Invoke-RestMethod -Uri "$ProwlarrUrl/api/v1/indexer" `
            -Headers @{ "X-Api-Key" = $ApiKey } -ErrorAction Stop | ForEach-Object { $_.name })
    }
    catch {
        Write-WarningMessage "Could not list existing Prowlarr indexers: $($_.Exception.Message)"
    }

    $added = 0
    $skipped = 0
    $failed = 0
    foreach ($indexer in $indexers) {
        if ($existingNames -contains $indexer.Name) {
            Write-Info "$($indexer.Name) already configured in Prowlarr (skipping)"
            $skipped++
            continue
        }
        if (Add-ProwlarrIndexer -ApiKey $ApiKey -Name $indexer.Name -BaseUrl $indexer.Url -DefinitionName $indexer.Definition) {
            $added++
        } else {
            $failed++
        }
    }

    # Honest summary - Prowlarr validates each indexer against the live site
    # on add, so geo-blocked/unreachable sites fail here (issue #29).
    Write-Info "Indexers: $added added, $skipped already present, $failed failed"
    if ($failed -gt 0) {
        Write-WarningMessage "Failed indexers are usually geo-blocked or down. If your ISP blocks torrent sites, route Prowlarr through a VPN or add indexers manually in the Prowlarr UI."
    }
}

function Sync-ProwlarrIndexer {
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
        Write-WarningMessage "Could not trigger sync"
    }
}

function Get-OverseerrApiKey {
    Write-Info "Retrieving Overseerr API key..."

    # API key is stored in settings.json after Plex OAuth sign-in.
    # Uses the script-scope $ConfigDir already resolved via Resolve-ConfigDir
    # in the main flow (.env autoload included — issue #29).
    $settingsPath = Join-Path $ConfigDir "overseerr\settings.json"
    
    if (-not (Test-Path $settingsPath)) {
        Write-WarningMessage "Overseerr settings.json not found at $settingsPath."
        Write-Info "If you have not signed in yet: sign in to Overseerr with Plex first."
        Write-Info "If you HAVE signed in: check DOCKER_CONFIG in your .env file (auto-loaded) or pass -ConfigDir / set DOCKER_CONFIG to override, then re-run."
        return $null
    }
    
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $apiKey = $settings.main.apiKey
        
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            Write-WarningMessage "Overseerr API key not found in settings"
            return $null
        }
        
        Write-Success "Overseerr API key retrieved"
        return $apiKey
    }
    catch {
        Write-WarningMessage "Could not read Overseerr settings: $($_.Exception.Message)"
        return $null
    }
}

# Check whether a service instance managed by this script already exists in
# Overseerr's settings. Matches by hostname — Overseerr may hold several
# Radarr/Sonarr instances (4K, anime) and only the one this script manages
# may be considered; matching "the first id" would target the wrong instance.
# Throws when the existence check itself fails — callers must NOT fall
# through to POST on failure, that recreates the issue #29 duplicate-server
# bug under a transient outage.
function Test-OverseerrServiceConfigured {
    param(
        [string]$OverseerrApiKey,
        [string]$Endpoint,
        [string]$ServiceHost
    )

    $existing = Invoke-RestMethod -Uri "$OverseerrUrl/api/v1/settings/$Endpoint" `
        -Headers @{ "X-Api-Key" = $OverseerrApiKey } `
        -ErrorAction Stop
    # @() guards the PS 5.1 single-element unwrap: Invoke-RestMethod turns a
    # one-entry JSON array into a scalar PSCustomObject with no .Count
    $configured = @(@($existing) | Where-Object { $_.hostname -eq $ServiceHost })
    return ($configured.Count -gt 0)
}

function Add-RadarrToOverseerr {
    param(
        [string]$RadarrApiKey,
        [string]$OverseerrApiKey
    )

    Write-Info "Adding Radarr to Overseerr..."

    # Existence check by hostname — never update an existing entry: it may
    # carry user customizations made in the Overseerr UI (quality profile,
    # root folder, tags) that a defaults-built request would silently destroy
    # (Overseerr's PUT replaces the entry, it does not merge).
    try {
        if (Test-OverseerrServiceConfigured -OverseerrApiKey $OverseerrApiKey -Endpoint "radarr" -ServiceHost $RadarrHost) {
            Write-Info "Radarr already configured in Overseerr (already configured, skipping)"
            return $true
        }
    }
    catch {
        Write-WarningMessage "Could not verify existing Radarr configuration in Overseerr: $($_.Exception.Message)"
        return $false
    }

    try {
        # Get Radarr profiles and root folders
        $radarrProfiles = Invoke-RestMethod -Uri "$RadarrUrl/api/v3/qualityprofile" -Headers @{ "X-Api-Key" = $RadarrApiKey } -ErrorAction Stop
        $rootFolders = Invoke-RestMethod -Uri "$RadarrUrl/api/v3/rootfolder" -Headers @{ "X-Api-Key" = $RadarrApiKey } -ErrorAction Stop
        
        if ($radarrProfiles.Count -eq 0 -or $rootFolders.Count -eq 0) {
            Write-WarningMessage "Radarr not fully configured (missing profiles or root folders)"
            return $false
        }
        
        $radarrConfig = @{
            name = "Radarr"
            hostname = $RadarrHost
            port = $RadarrPort
            apiKey = $RadarrApiKey
            useSsl = $false
            baseUrl = ""
            activeProfileId = $radarrProfiles[0].id
            # Overseerr's API schema requires activeProfileName as well (issue #29)
            activeProfileName = $radarrProfiles[0].name
            activeDirectory = $rootFolders[0].path
            is4k = $false
            minimumAvailability = "released"
            isDefault = $true
            externalUrl = ""
            syncEnabled = $true
            preventSearch = $false
        }
        
        Invoke-RestMethod -Uri "$OverseerrUrl/api/v1/settings/radarr" -Method Post -Headers @{
            "Content-Type" = "application/json"
            "X-Api-Key" = $OverseerrApiKey
        } -Body ($radarrConfig | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null

        Write-Success "Radarr added to Overseerr"
        return $true
    }
    catch {
        Write-WarningMessage "Failed to add Radarr to Overseerr: $($_.Exception.Message)"
        return $false
    }
}

function Add-SonarrToOverseerr {
    param(
        [string]$SonarrApiKey,
        [string]$OverseerrApiKey
    )
    
    Write-Info "Adding Sonarr to Overseerr..."

    # Existence check by hostname — never update an existing entry (see
    # Test-OverseerrServiceConfigured and Add-RadarrToOverseerr for rationale).
    try {
        if (Test-OverseerrServiceConfigured -OverseerrApiKey $OverseerrApiKey -Endpoint "sonarr" -ServiceHost $SonarrHost) {
            Write-Info "Sonarr already configured in Overseerr (already configured, skipping)"
            return $true
        }
    }
    catch {
        Write-WarningMessage "Could not verify existing Sonarr configuration in Overseerr: $($_.Exception.Message)"
        return $false
    }

    try {
        # Get Sonarr profiles and root folders
        $sonarrProfiles = Invoke-RestMethod -Uri "$SonarrUrl/api/v3/qualityprofile" -Headers @{ "X-Api-Key" = $SonarrApiKey } -ErrorAction Stop
        $rootFolders = Invoke-RestMethod -Uri "$SonarrUrl/api/v3/rootfolder" -Headers @{ "X-Api-Key" = $SonarrApiKey } -ErrorAction Stop
        
        if ($sonarrProfiles.Count -eq 0 -or $rootFolders.Count -eq 0) {
            Write-WarningMessage "Sonarr not fully configured (missing profiles or root folders)"
            return $false
        }
        
        $sonarrConfig = @{
            name = "Sonarr"
            hostname = $SonarrHost
            port = $SonarrPort
            apiKey = $SonarrApiKey
            useSsl = $false
            baseUrl = ""
            activeProfileId = $sonarrProfiles[0].id
            # Overseerr's API schema requires activeProfileName as well (issue #29)
            activeProfileName = $sonarrProfiles[0].name
            activeDirectory = $rootFolders[0].path
            is4k = $false
            isDefault = $true
            externalUrl = ""
            syncEnabled = $true
            preventSearch = $false
            enableSeasonFolders = $true
        }
        
        Invoke-RestMethod -Uri "$OverseerrUrl/api/v1/settings/sonarr" -Method Post -Headers @{
            "Content-Type" = "application/json"
            "X-Api-Key" = $OverseerrApiKey
        } -Body ($sonarrConfig | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null

        Write-Success "Sonarr added to Overseerr"
        return $true
    }
    catch {
        Write-WarningMessage "Failed to add Sonarr to Overseerr: $($_.Exception.Message)"
        return $false
    }
}

function Enable-OverseerrWatchlistSync {
    param([string]$OverseerrApiKey)

    Write-Info "Enabling Overseerr watchlist sync for the owner account..."

    # Watchlist sync is a PER-USER setting (POST /api/v1/user/{id}/settings/main),
    # not a field on /api/v1/settings/main — the previous implementation set
    # autoApproveMovie/autoApproveSeries properties that do not exist on the
    # main settings object, so it threw on every run (issue #29). The owner
    # (user 1, created by the Plex sign-in) auto-approves implicitly as admin.
    try {
        $body = @{ watchlistSyncMovies = $true; watchlistSyncTv = $true } | ConvertTo-Json

        $response = Invoke-RestMethod -Uri "$OverseerrUrl/api/v1/user/1/settings/main" -Method Post -Headers @{
            "Content-Type" = "application/json"
            "X-Api-Key" = $OverseerrApiKey
        } -Body $body -ErrorAction Stop

        if ($response.watchlistSyncMovies -eq $true) {
            Write-Success "Watchlist sync enabled (movies + TV) for the owner account"
            return $true
        }

        Write-WarningMessage "Could not enable watchlist sync (unexpected response)"
        return $false
    }
    catch {
        Write-WarningMessage "Could not enable watchlist sync: $($_.Exception.Message)"
        return $false
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

# Check if we should use local config files or wait for services.
# See Resolve-ConfigDir for the precedence chain, including .env autoload
# (issue #29, round 2).
$ConfigDir = Resolve-ConfigDir -ConfigDir $ConfigDir
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
    Write-WarningMessage "Services are running but API keys need to be provided."
    Write-Host ""
    $RadarrApiKey = Read-Host "Enter Radarr API key (from Settings > General)"
    $SonarrApiKey = Read-Host "Enter Sonarr API key (from Settings > General)"
    $ProwlarrApiKey = Read-Host "Enter Prowlarr API key (from Settings > General)"
}

Write-Header "Configuring Download Clients"

# Get qBittorrent password from logs if not provided
$QbPassword = Get-QBittorrentPassword -ContainerName "qbittorrent"
if (-not $QbPassword) {
    Write-WarningMessage "Could not retrieve qBittorrent password automatically."
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
Add-ProwlarrPublicIndexer -ApiKey $ProwlarrApiKey

Write-Info "Waiting 5 seconds for indexers to be added..."
Start-Sleep -Seconds 5

Sync-ProwlarrIndexer -ApiKey $ProwlarrApiKey

Write-Header "Configuring Overseerr"

Wait-ForService -Name "Overseerr" -Url $OverseerrUrl -Endpoint "/api/v1/status"

$overseerrApiKey = Get-OverseerrApiKey

if ($null -eq $overseerrApiKey) {
    Write-WarningMessage "Overseerr is not initialized. Sign in with your Plex account at $OverseerrUrl"
    Write-Info "After signing in, re-run this script to complete Overseerr configuration."
} else {
    Write-Info "Overseerr is initialized, configuring services..."
    Add-RadarrToOverseerr -RadarrApiKey $RadarrApiKey -OverseerrApiKey $overseerrApiKey
    Add-SonarrToOverseerr -SonarrApiKey $SonarrApiKey -OverseerrApiKey $overseerrApiKey
    Enable-OverseerrWatchlistSync -OverseerrApiKey $overseerrApiKey
    Write-Success "Overseerr configuration complete!"
}

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
Write-Host "║  ✓ Overseerr → Plex (watchlist monitoring)                             ║" -ForegroundColor Green
Write-Host "║  ✓ Overseerr → Radarr + Sonarr (auto-requests)                         ║" -ForegroundColor Green
Write-Host "║                                                                        ║" -ForegroundColor Green
Write-Host "║  Next Steps:                                                           ║" -ForegroundColor Green
Write-Host "║  1. Sign in to Overseerr with your Plex account                        ║" -ForegroundColor Green
Write-Host "║  2. Add a movie or show to your Plex watchlist                         ║" -ForegroundColor Green
Write-Host "║  3. Watch it automatically download and appear in your library!        ║" -ForegroundColor Green
Write-Host "║  4. (Optional) Add more indexers in Prowlarr                           ║" -ForegroundColor Green
Write-Host "║                                                                        ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
