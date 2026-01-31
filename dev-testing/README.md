# 🧪 Development Testing

**This directory contains automated test scripts for development and validation purposes only.**

> ⚠️ **Not for end users** — These tests are for contributors and development validation. Regular users don't need to run these scripts.

## What's Here

### test.ps1 (PowerShell)
Comprehensive test suite that validates the entire Simplarr setup:

- ✅ File existence and syntax validation
- ✅ Docker Compose file validation
- ✅ Service startup and connectivity tests
- ✅ API integration tests (API keys, connectivity, wiring)
- ✅ Configuration file validation
- ✅ Service wiring (qBittorrent → Radarr/Sonarr, Prowlarr → Apps, Indexers)
- ✅ End-to-end verification

**Cross-Platform:** Works on Windows, Linux, and macOS via PowerShell Core.

**Usage:**
```powershell
# Run all tests (full validation)
.\test.ps1

# Quick syntax checks only (skip container startup)
.\test.ps1 -Quick

# Auto-cleanup after tests
.\test.ps1 -Cleanup
```

**Test Results:**
- Creates isolated test containers (prefixed `simplarr-test-`)
- Uses production ports (80, 7878, 8989, 9696, 8080, 8181, 5055)
- Tests run in temporary directory (`$env:TEMP\simplarr-test-$PID`)
- ~83 tests covering all aspects of the setup

## When to Run Tests

**As a contributor:**
- Before submitting a pull request
- After making changes to compose files, scripts, or configs
- To validate architecture changes

**As a developer:**
- When experimenting with new features
- To ensure changes don't break existing functionality
- To validate that services wire together correctly

## What Gets Tested

### Phase 1: Pre-flight Checks
- Docker and Docker Compose availability
- Required files exist (compose files, scripts, nginx configs, homepage)

### Phase 2: Syntax Validation
- PowerShell script syntax (AST parsing)
- Docker Compose file structure validation
- Nginx configuration structure

### Phase 3: Template & Configuration
- qBittorrent template validation
- Nginx route validation
- Setup script completeness
- Configure script functionality

### Phase 4: Container Startup
- Test containers spin up successfully
- Health checks pass
- All services become responsive

### Phase 5: Service Connectivity
- Each service responds on expected port
- Homepage loads correctly via Nginx
- Status page accessible

### Phase 6: API Integration
- API keys generated correctly
- API endpoints respond
- Services can communicate

### Phase 7: Configuration File Validation
- Direct inspection of generated config files
- Radarr/Sonarr/Prowlarr: XML structure, API keys, ports
- qBittorrent: INI format, required sections
- Overseerr: JSON structure
- Tautulli: INI format

### Phase 8: Service Wiring (configure.sh simulation)
- Root folders added to Radarr/Sonarr
- qBittorrent added as download client to Radarr/Sonarr
- Radarr/Sonarr connected to Prowlarr
- Public indexers added to Prowlarr
- Prowlarr syncs indexers to apps

### Phase 9: Verification
- Confirm all wiring completed successfully
- Verify indexers propagated to Radarr/Sonarr
- Configuration summary

## Test Architecture

The tests use **production ports** (not test ports) because:
- Tests run in isolated environment (no conflicts)
- Validates exact production configuration
- Homepage JavaScript uses production ports
- Simplifies test maintenance

**Isolation:**
- All containers prefixed `simplarr-test-`
- Separate config directory in temp folder
- Separate Docker network
- Easy cleanup with container filter

## Key Learnings from Test Development

### qBittorrent Authentication
- Uses temporary password on first start (logged to console)
- Password is **plaintext** in logs (not hashed)
- Modifying config after password generation invalidates it
- Solution: Use default auth, extract password from logs

### No UrlBase Configuration Needed
- Services accessed via direct ports (`:7878`, `:8989`, etc.)
- Homepage uses JavaScript to build URLs dynamically
- Simpler than path-based routing (no UrlBase, no restarts)
- Nginx only serves homepage, not reverse proxy for apps

### Homepage Architecture
- Static HTML with JavaScript port configuration
- Detects hostname automatically (`window.location.hostname`)
- Builds URLs: `${protocol}//${host}:${port}/`
- Trailing slash required for proper loading

## Cleanup

Test containers remain running after tests (for inspection). To clean up:

```powershell
# Manual cleanup
docker ps -a --filter "name=simplarr-test" --format "{{.ID}}" | ForEach-Object { docker rm -f $_ }

# Or with compose (if you saved the test dir)
cd C:\Users\...\AppData\Local\Temp\simplarr-test-XXXXX
docker compose -f docker-compose-test.yml down -v

# Or use -Cleanup flag
.\test.ps1 -Cleanup
```

## Contributing

When making changes that affect:
- Docker Compose files → Run full tests
- Setup/configure scripts → Run full tests
- Nginx configs → Run at least quick tests + container tests
- Homepage → Run container tests + manual browser check
- Documentation only → Quick tests sufficient

**Before submitting PR:**
1. Run `.\test.ps1` and ensure all tests pass
2. Document any new test cases added
3. Update this README if test structure changes
