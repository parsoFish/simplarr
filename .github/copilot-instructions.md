# Simplarr - GitHub Copilot Instructions

## Project Overview

**Simplarr** automates Plex media server setup using Docker Compose. PowerShell and Bash scripts configure services via REST APIs: Plex, Radarr, Sonarr, Prowlarr, qBittorrent, Overseerr.

- **Type**: Docker Compose automation (PowerShell, Bash, YAML)
- **Key Scripts**: `setup.ps1/sh` (interactive config), `configure.ps1/sh` (API automation), `test.ps1` (integration tests)
- **Deployment**: Unified (one machine) or Split (NAS + Pi/Server)

## Critical Patterns (MUST FOLLOW)

### 1. API Key Retrieval - MOST IMPORTANT

**ALWAYS read API keys from service config files (XML/JSON), NEVER from environment variables.**

Services generate API keys on first run and store them locally. Configure scripts MUST:
1. Wait for config file to exist (max 30 attempts, 2-second intervals)
2. Read API key from file (XML: `<ApiKey>`, JSON: `"apiKey"`)
3. Return `$null` if file not found (graceful failure)

**Config file locations:**
- Radarr/Sonarr/Prowlarr: `$DOCKER_CONFIG/<service>/config.xml` → `<ApiKey>value</ApiKey>`
- Overseerr: `$DOCKER_CONFIG/overseerr/settings.json` → `"main": {"apiKey": "value"}`

### 2. Service Configuration Order - MANDATORY

Execute in this exact order (dependencies):
1. **Radarr** → Configure download client + root folder
2. **Sonarr** → Configure download client + root folder  
3. **Prowlarr** → Add indexers, THEN sync to Radarr/Sonarr (needs their API keys)
4. **Overseerr** → Check initialization, get API key, configure services

**NEVER configure Prowlarr before Radarr/Sonarr are ready.**

### 3. OAuth Cannot Be Automated

**Overseerr requires manual Plex OAuth sign-in** (one-time, browser-based). Cannot be scripted.

**Flow:**
1. User signs in to Overseerr with Plex account → generates API key in `settings.json`
2. Configure script checks initialization, reads API key, configures services
3. If not initialized, skip gracefully with clear warning:
   ```powershell
   Write-Warning "Overseerr not initialized. Sign in at $OverseerrUrl"
   Write-Warning "After signing in, run this script again"
   ```

### 4. Always Wait for Services

Before configuration, wait for service health check (max 30 attempts, 2-second intervals):
```powershell
$response = Invoke-WebRequest -Uri "$ServiceUrl/api/status" -TimeoutSec 5
if ($response.StatusCode -eq 200) { # Service ready }
```

### 5. Authentication Headers Required

**ALWAYS include X-Api-Key header** in API requests:
```powershell
# CORRECT
Invoke-RestMethod -Uri "$RadarrUrl/api/v3/indexer" -Headers @{
    "X-Api-Key" = $RadarrApiKey
    "Content-Type" = "application/json"
}

# WRONG - Missing auth, returns 401
Invoke-RestMethod -Uri "$RadarrUrl/api/v3/indexer" -Headers @{
    "Content-Type" = "application/json"
}
```

### 6. Test Design - Handle Uninitialized Services

Tests MUST check initialization before running:
```powershell
$serviceInitialized = $false
try {
    $status = Invoke-RestMethod -Uri "$ServiceUrl/api/status" -TimeoutSec 10
    $serviceInitialized = $status.initialized -eq $true
} catch { $serviceInitialized = $false }

if (-not $serviceInitialized) {
    Write-Skip "Service tests (requires manual setup)"
} else {
    # Run tests
}
```

## Build and Validation

### Setup Commands
```powershell
# 1. Interactive setup
.\setup.ps1  # Creates .env, directory structure

# 2. Start containers
docker compose -f docker-compose-unified.yml up -d

# 3. Complete Plex setup (browser)
# - http://localhost:32400/web
# - Sign in, add libraries: Movies → /movies, TV → /tv

# 4. Auto-configure services
.\configure.ps1  # Wires services via REST APIs

# 5. Complete Overseerr (browser)
# - http://localhost:5055
# - Sign in with Plex (OAuth)
# - Run .\configure.ps1 again
```

### Testing Commands
```powershell
.\dev-testing\test.ps1 -Quick     # Syntax validation (30 sec)
.\dev-testing\test.ps1            # Full integration tests (15 min)
.\dev-testing\test.ps1 -Cleanup   # With test cleanup
```

## Common Issues

**"401 Unauthorized"** → Service not initialized or missing API key in headers  
**"Config file not found"** → Service hasn't created config yet (wait longer)  
**"Service not ready"** → Check Docker logs: `docker logs <service-name>`  
**Prowlarr fails** → Radarr/Sonarr must be configured first

## Development Rules

### PowerShell/Bash Parity
Both `configure.ps1` and `configure.sh` MUST maintain feature parity:
- Identical function signatures and behavior
- Same error messages and user feedback
- Test both scripts after any change

### Code Style
**PowerShell:** PascalCase functions (`Get-RadarrApiKey`), explicit error handling  
**Bash:** snake_case functions (`get_radarr_api_key`), always quote variables

### Error Messages
```powershell
# GOOD - Clear, actionable
Write-Warning "Overseerr not initialized. Sign in at http://localhost:5055"
Write-Warning "After signing in, run: .\configure.ps1"

# BAD - Vague
Write-Warning "Configuration failed"
```

### Adding New Service Integration
1. Research: API key location, OAuth requirements?
2. Create `Get-ServiceApiKey` function (read from config file)
3. Add configuration functions with API key parameters
4. Update main execution flow (wait → get key → configure)
5. Write tests (handle uninitialized state)
6. Update both PS1 and SH scripts
7. Document manual steps in README

## Common Pitfalls

### ❌ DON'T
- Assume services have API keys before first run
- Try to automate OAuth flows (impossible)
- Make API calls without X-Api-Key header
- Configure services before they're ready
- Claim features are "fully automated" if they require manual steps
- Update only one script (breaks parity)

### ✅ DO
- Read API keys from service config files
- Wait for service health checks before configuration
- Handle uninitialized services gracefully (skip with warning)
- Provide clear, actionable error messages
- Document manual steps transparently
- Maintain PowerShell/Bash parity

## Directory Structure

```
configure.ps1/sh     # API automation (CRITICAL - service wiring)
setup.ps1/sh         # Interactive .env setup
dev-testing/test.ps1 # Integration tests
docker-compose-*.yml # Service definitions (unified/nas/pi)
nginx/*.conf         # Reverse proxy configs
templates/           # Pre-configured service templates
```

## Trust These Instructions

Follow this exact order for all service integrations:
1. Read API keys from config files (NOT env vars)
2. Configure in order: Radarr → Sonarr → Prowlarr → Overseerr
3. Handle OAuth with clear user guidance (cannot automate)
4. Wait for service health checks before API calls
5. Test with uninitialized services (graceful skip)
6. Maintain PowerShell/Bash parity
7. Document manual steps honestly

These patterns prevent the bugs that were fixed in this codebase. Only search for additional context if these instructions are incomplete or incorrect.
