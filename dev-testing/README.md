# Development Testing

**This directory contains automated test scripts for development and validation purposes only.**

> **Not for end users** — These tests are for contributors and development validation. Regular users don't need to run these scripts.

## What's Here

### test.ps1 (PowerShell)

Comprehensive test suite that validates the entire Simplarr setup:

- File existence and syntax validation
- Docker Compose file validation
- Service startup and connectivity tests
- API integration tests (API keys, connectivity, wiring)
- Configuration file validation
- Service wiring (qBittorrent to Radarr/Sonarr, Prowlarr to Apps, Indexers)
- End-to-end verification

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

---

### test.sh (Bash)

Equivalent test suite for Linux/macOS that mirrors `test.ps1` phases 1-7 and adds container integration tests in phases 8-9.

#### Prerequisites

| Tool | Required? | Notes |
|------|-----------|-------|
| bash 4+ | Required | Uses `declare -a`, `(( ))` arithmetic, `[[ ]]` conditionals |
| Docker | Required for phases 8-9 | Phases 1-7 run without Docker; phases 8-9 are skipped if unavailable |
| docker compose (v2) | Required for phases 8-9 | Plugin form (`docker compose`), not standalone `docker-compose` |
| ShellCheck | Optional (linting) | Install via `apt install shellcheck` or `brew install shellcheck`; used to lint test scripts |

#### Running test.sh

```bash
# Run the full test suite (phases 1-9)
bash dev-testing/test.sh

# Or from the repo root
./dev-testing/test.sh
```

Phases 1-7 cover syntax, file existence, and configuration checks — equivalent to the `-Quick` flag in `test.ps1`. These run without Docker. Phases 8-9 require Docker and spin up live containers.

To run only the non-container checks (phases 1-7), ensure Docker is unavailable or explicitly unset in your PATH; phases 8-9 are automatically skipped when `docker compose` is not found.

#### Output Interpretation

Each test line is prefixed with one of three indicators:

| Indicator | Meaning |
|-----------|---------|
| `[PASS]` | Test passed |
| `[FAIL]` | Test failed — review output for details |
| `[SKIP]` | Test skipped (usually because Docker is unavailable) |

**Exit codes:** `0` = all tests passed, `1` = one or more failures.

A summary line at the end shows total pass and fail counts.

#### Port Isolation Strategy (Phases 8-9)

Phases 8-9 start live Docker containers. To avoid port conflicts with production services or other test runs, `test.sh` uses **random port isolation**: a random base port is chosen in the range `20000`-`29999`, safely above well-known ports and typical production port assignments.

Each service is assigned a port offset from this base:

```bash
# Override with a fixed port for deterministic CI assignments
SIMPLARR_TEST_BASE_PORT=25000 ./dev-testing/test.sh
```

Set `SIMPLARR_TEST_BASE_PORT` to override the random selection — useful in CI environments where you want deterministic port assignments or need to avoid a specific port range.

#### Cleanup Mechanism

`test.sh` registers an **EXIT trap** that runs automatically whenever the script exits — whether it completes normally, fails, or is interrupted (Ctrl+C). The trap runs:

```bash
docker compose down --volumes --remove-orphans
```

This means containers and volumes are always cleaned up automatically — no `-Cleanup` flag is needed (unlike `test.ps1`). The automatic cleanup ensures no orphaned containers or volumes are left behind even on failure.

---

## Phase Correspondence Table

The two test runners cover similar ground with different phase numbering. Some test.ps1 phases (API integration, service wiring, verification) have no Bash equivalent — they require PowerShell-specific tooling.

| test.ps1 Phase | test.sh Phase | Description |
|----------------|---------------|-------------|
| Phase 1: Pre-flight | Phase 1: Preflight | Docker/tool availability, required files |
| Phase 2: Syntax Validation | Phase 3: Syntax Validation | Docker Compose and config syntax |
| Phase 3: Template & Configuration | Phases 4-7: Nginx, qBT, Setup, Configure | Config content and script completeness checks |
| Phase 4: Container Startup | Phase 8: Container Startup | Spin up containers, wait for healthy status |
| Phase 5: Service Connectivity | Phase 9: Service Connectivity | HTTP endpoint reachability checks |
| Phase 6: API Integration | *(not in test.sh)* | API key validation, service communication |
| Phase 7: Config File Validation | *(not in test.sh)* | Deep XML/INI/JSON config inspection |
| Phase 8: Service Wiring | *(not in test.sh)* | configure.sh simulation, Radarr/Sonarr/Prowlarr wiring |
| Phase 9: Verification | *(not in test.sh)* | Wiring confirmation, indexer propagation |
| *(not in test.ps1)* | Phase 2: File Existence | Bash-specific file presence checks |

**Summary:** `test.sh` phases 1-7 correspond to the `-Quick` flag scope of `test.ps1` (no containers). Phases 8-9 in `test.sh` map to phases 4-5 in `test.ps1`.

---

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

---

## Test Architecture

### test.ps1
- Uses **production ports** (not test ports) — validates exact production configuration
- All containers prefixed `simplarr-test-`
- Separate config directory in temp folder
- Separate Docker network
- Easy cleanup with container filter

### test.sh
- Uses **random port isolation** (20000-29999) to avoid conflicts
- EXIT trap guarantees automatic cleanup of containers and volumes
- Phases 8-9 skipped gracefully when Docker is unavailable

---

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

---

## Contributor Workflow

When making changes that affect:
- Docker Compose files — run full tests
- Setup/configure scripts — run full tests
- Nginx configs — run at least quick tests + container tests
- Homepage — run container tests + manual browser check
- Documentation only — quick tests sufficient

**Before submitting a PR, both test suites must pass:**

```bash
# Bash suite (Linux/macOS)
./dev-testing/test.sh

# PowerShell suite (all platforms)
pwsh ./dev-testing/test.ps1
```

1. Run `./dev-testing/test.sh` and ensure all tests pass before opening a PR
2. Run `.\test.ps1` (or `pwsh ./dev-testing/test.ps1`) and ensure all test.ps1 tests pass before opening a PR
3. Document any new test cases added
4. Update this README if test structure changes
