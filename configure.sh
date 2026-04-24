#!/bin/bash
# =============================================================================
# Simplarr Configuration Script
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

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration - override with environment variables or arguments
RADARR_URL="${RADARR_URL:-http://localhost:7878}"
SONARR_URL="${SONARR_URL:-http://localhost:8989}"
PROWLARR_URL="${PROWLARR_URL:-http://localhost:9696}"
QBITTORRENT_URL="${QBITTORRENT_URL:-http://localhost:8080}"
OVERSEERR_URL="${OVERSEERR_URL:-http://localhost:5055}"
TAUTULLI_URL="${TAUTULLI_URL:-http://localhost:8181}"

# Service ports — single source of truth; referenced in API payloads below
RADARR_PORT="${RADARR_PORT:-7878}"
SONARR_PORT="${SONARR_PORT:-8989}"
PROWLARR_PORT="${PROWLARR_PORT:-9696}"
QBITTORRENT_PORT="${QBITTORRENT_PORT:-8080}"

# Retry configuration for wait_for_service
WAIT_MAX_ATTEMPTS="${WAIT_MAX_ATTEMPTS:-30}"
WAIT_RETRY_SECS="${WAIT_RETRY_SECS:-2}"

# Internal Docker network names (used when configuring connections between services)
RADARR_HOST="${RADARR_HOST:-radarr}"
SONARR_HOST="${SONARR_HOST:-sonarr}"
PROWLARR_HOST="${PROWLARR_HOST:-prowlarr}"
QBITTORRENT_HOST="${QBITTORRENT_HOST:-qbittorrent}"
PLEX_HOST="${PLEX_HOST:-plex}"
OVERSEERR_HOST="${OVERSEERR_HOST:-overseerr}"

# Paths inside containers
MOVIES_PATH="${MOVIES_PATH:-/movies}"
TV_PATH="${TV_PATH:-/tv}"
DOWNLOADS_PATH="${DOWNLOADS_PATH:-/downloads}"

# qBittorrent credentials
# Username defaults to admin, password must be retrieved from logs or provided
QB_USERNAME="${QB_USERNAME:-admin}"
QB_PASSWORD="${QB_PASSWORD:-}"

# Prowlarr public indexer definitions — each entry encodes name|base_url|definition_name|impl_name.
# Adding a new indexer requires only a new data entry here; no changes to add_public_indexers().
INDEXER_DEFINITIONS=(
    "YTS|https://yts.mx|yts|YTS"                                          # definitionName: "yts"
    "The Pirate Bay|https://thepiratebay.org|thepiratebay|The Pirate Bay" # definitionName: "thepiratebay"
    "TorrentGalaxy|https://torrentgalaxy.to|torrentgalaxy|TorrentGalaxy"  # definitionName: "torrentgalaxy"
    "Nyaa|https://nyaa.si|nyaasi|Nyaa.si"                                 # definitionName: "nyaasi"
    "LimeTorrents|https://www.limetorrents.lol|limetorrents|LimeTorrents" # definitionName: "limetorrents"
)

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║                    Simplarr Configuration Script                       ║"
echo "║                                                                        ║"
echo "║  This script will wire up your *arr services automatically.            ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Wait for a service to be ready
wait_for_service() {
    local name=$1
    local url=$2
    local endpoint=$3
    local max_attempts="${WAIT_MAX_ATTEMPTS:-30}"
    local attempt=1

    log_info "Waiting for $name to be ready..."

    while [ "$attempt" -le "$max_attempts" ]; do
        if curl -s -o /dev/null -w "%{http_code}" "${url}${endpoint}" | grep -q "200\|401\|302"; then
            log_success "$name is ready"
            return 0
        fi
        echo -n "."
        sleep "${WAIT_RETRY_SECS:-2}"
        attempt=$((attempt + 1))
    done

    log_error "$name is not responding after $max_attempts attempts"
    return 1
}

# Get API key from *arr service config
get_arr_api_key() {
    local name=$1
    local config_path=$2

    if [ -f "$config_path" ]; then
        local api_key
        api_key=$(grep -oP '(?<=<ApiKey>)[^<]+' "$config_path" 2>/dev/null || echo "")
        if [ -n "$api_key" ]; then
            echo "$api_key"
            return 0
        fi
    fi

    log_error "Could not get API key for $name from $config_path"
    return 1
}

# Get qBittorrent temporary password from docker logs
get_qbittorrent_password() {
    local container_name="${1:-${QBITTORRENT_CONTAINER:-qbittorrent}}"

    if [ -n "$QB_PASSWORD" ]; then
        echo "$QB_PASSWORD"
        return 0
    fi

    # Log messages go to stderr so they don't pollute the captured return value.
    log_info "Retrieving qBittorrent temporary password from logs..." >&2

    local password
    password=$(docker logs "$container_name" 2>&1 | grep -oP 'temporary password[^:]*:\s*\K\S+' | tail -1)

    if [ -n "$password" ]; then
        log_success "Retrieved qBittorrent password" >&2
        echo "$password"
        return 0
    fi

    log_error "Could not retrieve qBittorrent password from logs" >&2
    log_info "You can set QB_PASSWORD environment variable manually" >&2
    return 1
}

# =============================================================================
# Service Configuration Functions
# =============================================================================

# Add qBittorrent as download client to a *arr service.
# Parameters:
#   $1 service_url           — base URL of the target service (e.g. http://localhost:7878)
#   $2 api_key               — X-Api-Key for the target service
#   $3 category_field        — JSON field name for the category (e.g. movieCategory, tvCategory)
#   $4 category_value        — value for the category field (e.g. radarr, sonarr)
#   $5 recent_priority_field — JSON field name for recent download priority
#   $6 older_priority_field  — JSON field name for older download priority
add_qbittorrent_download_client() {
    local service_url="$1"
    local api_key="$2"
    local category_field="$3"
    local category_value="$4"
    local recent_priority_field="$5"
    local older_priority_field="$6"
    # Derive the imported-category field name by inserting "Imported" before "Category"
    # e.g. movieCategory → movieImportedCategory, tvCategory → tvImportedCategory
    local imported_category_field="${category_field/Category/ImportedCategory}"

    # GET-before-POST: skip if qBittorrent download client already configured
    local existing
    existing=$(curl -s "${service_url}/api/v3/downloadclient" \
        -H "X-Api-Key: ${api_key}")
    if echo "${existing}" | grep -q '"name" *: *"qBittorrent"'; then
        log_info "qBittorrent already configured (skipping)"
        return 0
    fi

    # *arr services validate the qBittorrent connection on POST and return HTTP 400
    # if qBittorrent is unreachable.  Try enabled first (normal case); fall back
    # to disabled so the entry exists and the script stays idempotent on re-runs.
    local response enable
    for enable in true false; do
        response=$(curl -s -X POST "${service_url}/api/v3/downloadclient" \
            -H "X-Api-Key: ${api_key}" \
            -H "Content-Type: application/json" \
            -d "{
                \"enable\": ${enable},
                \"protocol\": \"torrent\",
                \"priority\": 1,
                \"removeCompletedDownloads\": true,
                \"removeFailedDownloads\": true,
                \"name\": \"qBittorrent\",
                \"fields\": [
                    {\"name\": \"host\", \"value\": \"${QBITTORRENT_HOST}\"},
                    {\"name\": \"port\", \"value\": ${QBITTORRENT_PORT}},
                    {\"name\": \"useSsl\", \"value\": false},
                    {\"name\": \"urlBase\", \"value\": \"\"},
                    {\"name\": \"username\", \"value\": \"${QB_USERNAME}\"},
                    {\"name\": \"password\", \"value\": \"${QB_PASSWORD}\"},
                    {\"name\": \"${category_field}\", \"value\": \"${category_value}\"},
                    {\"name\": \"${imported_category_field}\", \"value\": \"\"},
                    {\"name\": \"${recent_priority_field}\", \"value\": 0},
                    {\"name\": \"${older_priority_field}\", \"value\": 0},
                    {\"name\": \"initialState\", \"value\": 0},
                    {\"name\": \"sequentialOrder\", \"value\": false},
                    {\"name\": \"firstAndLast\", \"value\": false}
                ],
                \"implementationName\": \"qBittorrent\",
                \"implementation\": \"QBittorrent\",
                \"configContract\": \"QBittorrentSettings\",
                \"tags\": []
            }")
        if echo "${response}" | grep -q '"id"'; then
            break
        fi
        [[ "${enable}" == "true" ]] && \
            log_warn "qBittorrent unreachable — adding as disabled so re-runs stay idempotent"
    done

    if echo "${response}" | grep -q '"id"'; then
        log_success "qBittorrent added to service"
        return 0
    else
        log_warn "qBittorrent may already exist or failed to add"
        return 1
    fi
}

# Add qBittorrent as download client to Radarr
add_qbittorrent_to_radarr() {
    local api_key="$1"
    log_info "Adding qBittorrent to Radarr..."
    add_qbittorrent_download_client \
        "${RADARR_URL}" "${api_key}" \
        "movieCategory" "radarr" \
        "recentMoviePriority" "olderMoviePriority"
}

# Add qBittorrent as download client to Sonarr
add_qbittorrent_to_sonarr() {
    local api_key="$1"
    log_info "Adding qBittorrent to Sonarr..."
    add_qbittorrent_download_client \
        "${SONARR_URL}" "${api_key}" \
        "tvCategory" "sonarr" \
        "recentTvPriority" "olderTvPriority"
}

# Add Radarr to Prowlarr for indexer sync
add_radarr_to_prowlarr() {
    local prowlarr_key=$1
    local radarr_key=$2

    log_info "Adding Radarr to Prowlarr..."

    # GET-before-POST: skip if Radarr application already configured in Prowlarr
    local existing
    existing=$(curl -s "${PROWLARR_URL}/api/v1/applications" \
        -H "X-Api-Key: ${prowlarr_key}")
    if echo "${existing}" | grep -q '"name" *: *"Radarr"'; then
        log_info "Radarr already configured in Prowlarr (already configured, skipping)"
        return 0
    fi

    local response
    response=$(curl -s -X POST "${PROWLARR_URL}/api/v1/applications" \
        -H "X-Api-Key: ${prowlarr_key}" \
        -H "Content-Type: application/json" \
        -d "{
            \"syncLevel\": \"fullSync\",
            \"name\": \"Radarr\",
            \"fields\": [
                {\"name\": \"prowlarrUrl\", \"value\": \"http://${PROWLARR_HOST}:${PROWLARR_PORT}\"},
                {\"name\": \"baseUrl\", \"value\": \"http://${RADARR_HOST}:${RADARR_PORT}\"},
                {\"name\": \"apiKey\", \"value\": \"${radarr_key}\"},
                {\"name\": \"syncCategories\", \"value\": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]}
            ],
            \"implementationName\": \"Radarr\",
            \"implementation\": \"Radarr\",
            \"configContract\": \"RadarrSettings\",
            \"tags\": []
        }")

    if echo "$response" | grep -q '"id"'; then
        log_success "Radarr added to Prowlarr"
        return 0
    else
        log_warn "Radarr may already exist in Prowlarr or failed to add"
        return 1
    fi
}

# Add Sonarr to Prowlarr for indexer sync
add_sonarr_to_prowlarr() {
    local prowlarr_key=$1
    local sonarr_key=$2

    log_info "Adding Sonarr to Prowlarr..."

    # GET-before-POST: skip if Sonarr application already configured in Prowlarr
    local existing
    existing=$(curl -s "${PROWLARR_URL}/api/v1/applications" \
        -H "X-Api-Key: ${prowlarr_key}")
    if echo "${existing}" | grep -q '"name" *: *"Sonarr"'; then
        log_info "Sonarr already configured in Prowlarr (already configured, skipping)"
        return 0
    fi

    local response
    response=$(curl -s -X POST "${PROWLARR_URL}/api/v1/applications" \
        -H "X-Api-Key: ${prowlarr_key}" \
        -H "Content-Type: application/json" \
        -d "{
            \"syncLevel\": \"fullSync\",
            \"name\": \"Sonarr\",
            \"fields\": [
                {\"name\": \"prowlarrUrl\", \"value\": \"http://${PROWLARR_HOST}:${PROWLARR_PORT}\"},
                {\"name\": \"baseUrl\", \"value\": \"http://${SONARR_HOST}:${SONARR_PORT}\"},
                {\"name\": \"apiKey\", \"value\": \"${sonarr_key}\"},
                {\"name\": \"syncCategories\", \"value\": [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]}
            ],
            \"implementationName\": \"Sonarr\",
            \"implementation\": \"Sonarr\",
            \"configContract\": \"SonarrSettings\",
            \"tags\": []
        }")

    if echo "$response" | grep -q '"id"'; then
        log_success "Sonarr added to Prowlarr"
        return 0
    else
        log_warn "Sonarr may already exist in Prowlarr or failed to add"
        return 1
    fi
}

# Add root folder to Radarr
add_radarr_root_folder() {
    local api_key=$1

    log_info "Adding root folder to Radarr..."

    # GET-before-POST: skip if /movies root folder already configured
    local existing
    existing=$(curl -s "${RADARR_URL}/api/v3/rootfolder" \
        -H "X-Api-Key: ${api_key}")
    if echo "${existing}" | grep -q "\"path\" *: *\"${MOVIES_PATH}\""; then
        log_info "Root folder ${MOVIES_PATH} already configured in Radarr (already configured, skipping)"
        return 0
    fi

    local response
    response=$(curl -s -X POST "${RADARR_URL}/api/v3/rootfolder" \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{
            \"path\": \"${MOVIES_PATH}\"
        }")

    if echo "$response" | grep -q '"id"'; then
        log_success "Root folder added to Radarr: ${MOVIES_PATH}"
        return 0
    else
        log_warn "Root folder may already exist in Radarr"
        return 1
    fi
}

# Add root folder to Sonarr
add_sonarr_root_folder() {
    local api_key=$1

    log_info "Adding root folder to Sonarr..."

    # GET-before-POST: skip if /tv root folder already configured
    local existing
    existing=$(curl -s "${SONARR_URL}/api/v3/rootfolder" \
        -H "X-Api-Key: ${api_key}")
    if echo "${existing}" | grep -q "\"path\" *: *\"${TV_PATH}\""; then
        log_info "Root folder ${TV_PATH} already configured in Sonarr (already configured, skipping)"
        return 0
    fi

    local response
    response=$(curl -s -X POST "${SONARR_URL}/api/v3/rootfolder" \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{
            \"path\": \"${TV_PATH}\"
        }")

    if echo "$response" | grep -q '"id"'; then
        log_success "Root folder added to Sonarr: ${TV_PATH}"
        return 0
    else
        log_warn "Root folder may already exist in Sonarr"
        return 1
    fi
}

# Add a single public indexer to Prowlarr.
# Parameters:
#   $1 api_key         — Prowlarr X-Api-Key
#   $2 name            — display name shown in Prowlarr UI
#   $3 base_url        — base URL for the indexer site
#   $4 definition_name — Prowlarr's internal definitionName (Cardigann schema ID)
#   $5 impl_name       — implementationName reported to Prowlarr (defaults to $2 if omitted)
add_indexer() {
    local api_key="$1"
    local name="$2"
    local base_url="$3"
    local definition_name="$4"
    local impl_name="${5:-${name}}"

    if curl -s -X POST "${PROWLARR_URL}/api/v1/indexer" \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{
            \"enable\": true,
            \"redirect\": false,
            \"name\": \"${name}\",
            \"fields\": [
                {\"name\": \"baseUrl\", \"value\": \"${base_url}\"},
                {\"name\": \"baseSettings.limitsUnit\", \"value\": 0}
            ],
            \"implementationName\": \"${impl_name}\",
            \"implementation\": \"Cardigann\",
            \"configContract\": \"CardigannSettings\",
            \"definitionName\": \"${definition_name}\",
            \"tags\": [],
            \"priority\": 25,
            \"appProfileId\": 1
        }" >/dev/null 2>&1; then
        log_success "Added ${name}"
    else
        log_warn "${name} may already exist"
    fi
}

# Add popular public indexers to Prowlarr
# NOTE: Some indexers may be blocked in certain countries or have Cloudflare
#       protection. Add them manually in Prowlarr if needed.
add_public_indexers() {
    local api_key="$1"

    log_info "Adding public indexers to Prowlarr..."
    log_info "Note: Some indexers may fail due to geo-blocking or Cloudflare protection"

    # GET-before-POST: fetch existing indexers once to detect duplicates
    local existing_indexers
    existing_indexers=$(curl -s "${PROWLARR_URL}/api/v1/indexer" \
        -H "X-Api-Key: ${api_key}")

    local entry name base_url def_name impl_name
    for entry in "${INDEXER_DEFINITIONS[@]}"; do
        IFS='|' read -r name base_url def_name impl_name <<< "${entry}"
        if echo "${existing_indexers}" | grep -q "\"name\" *: *\"${name}\""; then
            log_info "${name} already configured in Prowlarr (skipping)"
            continue
        fi
        add_indexer "${api_key}" "${name}" "${base_url}" "${def_name}" "${impl_name}"
    done
}

# Trigger Prowlarr to sync indexers to apps
sync_prowlarr_indexers() {
    local api_key=$1

    log_info "Triggering Prowlarr indexer sync..."

    curl -s -X POST "${PROWLARR_URL}/api/v1/command" \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d '{"name": "ApplicationIndexerSync"}' >/dev/null 2>&1

    log_success "Indexer sync triggered"
}

# =============================================================================
# Overseerr Configuration Functions
# =============================================================================

# Check if Overseerr is already initialized
# Get Overseerr API key from settings.json
get_overseerr_api_key() {
    log_info "Retrieving Overseerr API key..."

    local settings_path="${DOCKER_CONFIG}/overseerr/settings.json"

    if [ ! -f "$settings_path" ]; then
        log_error "Overseerr settings.json not found. User must sign in with Plex first."
        return 1
    fi

    local api_key
    api_key=$(grep -o '"apiKey":"[^"]*"' "$settings_path" | cut -d'"' -f4)

    if [ -z "$api_key" ]; then
        log_error "Overseerr API key not found in settings"
        return 1
    fi

    log_success "Overseerr API key retrieved"
    echo "$api_key"
    return 0
}

initialize_overseerr() {
    log_info "Checking Overseerr initialization status..."

    # /api/v1/status returns only version info. The `initialized` flag
    # lives on /api/v1/settings/public (unauthenticated, exposes which
    # setup steps have been completed).
    local settings_response
    settings_response=$(curl -s "${OVERSEERR_URL}/api/v1/settings/public")

    if echo "$settings_response" | grep -q '"initialized":true'; then
        log_info "Overseerr is already initialized"
        return 0
    else
        log_info "Overseerr is not yet initialized"
        return 1
    fi
}

# Add Radarr to Overseerr
add_radarr_to_overseerr() {
    local radarr_api_key=$1
    local overseerr_api_key=$2

    log_info "Adding Radarr to Overseerr..."

    # Get Radarr quality profiles
    local profiles
    profiles=$(curl -s -H "X-Api-Key: ${radarr_api_key}" \
        "${RADARR_URL}/api/v3/qualityprofile")
    local profile_id
    profile_id=$(echo "$profiles" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

    # Get Radarr root folders
    local root_folders
    root_folders=$(curl -s -H "X-Api-Key: ${radarr_api_key}" \
        "${RADARR_URL}/api/v3/rootfolder")
    local root_path
    root_path=$(echo "$root_folders" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$profile_id" ] || [ -z "$root_path" ]; then
        log_error "Failed to get Radarr configuration"
        return 1
    fi

    local radarr_config="{
        \"name\": \"Radarr\",
        \"hostname\": \"${RADARR_HOST}\",
        \"port\": ${RADARR_PORT},
        \"apiKey\": \"${radarr_api_key}\",
        \"useSsl\": false,
        \"baseUrl\": \"\",
        \"activeProfileId\": ${profile_id},
        \"activeDirectory\": \"${root_path}\",
        \"is4k\": false,
        \"minimumAvailability\": \"released\",
        \"isDefault\": true,
        \"externalUrl\": \"\",
        \"syncEnabled\": true
    }"

    local response
    response=$(curl -s -X POST "${OVERSEERR_URL}/api/v1/settings/radarr" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${overseerr_api_key}" \
        -d "$radarr_config")

    if echo "$response" | grep -q '"id"'; then
        log_success "Radarr added to Overseerr"
        return 0
    else
        log_error "Failed to add Radarr to Overseerr"
        return 1
    fi
}

# Add Sonarr to Overseerr
add_sonarr_to_overseerr() {
    local sonarr_api_key=$1
    local overseerr_api_key=$2

    log_info "Adding Sonarr to Overseerr..."

    # Get Sonarr quality profiles
    local profiles
    profiles=$(curl -s -H "X-Api-Key: ${sonarr_api_key}" \
        "${SONARR_URL}/api/v3/qualityprofile")
    local profile_id
    profile_id=$(echo "$profiles" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

    # Get Sonarr root folders
    local root_folders
    root_folders=$(curl -s -H "X-Api-Key: ${sonarr_api_key}" \
        "${SONARR_URL}/api/v3/rootfolder")
    local root_path
    root_path=$(echo "$root_folders" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$profile_id" ] || [ -z "$root_path" ]; then
        log_error "Failed to get Sonarr configuration"
        return 1
    fi

    local sonarr_config="{
        \"name\": \"Sonarr\",
        \"hostname\": \"${SONARR_HOST}\",
        \"port\": ${SONARR_PORT},
        \"apiKey\": \"${sonarr_api_key}\",
        \"useSsl\": false,
        \"baseUrl\": \"\",
        \"activeProfileId\": ${profile_id},
        \"activeDirectory\": \"${root_path}\",
        \"is4k\": false,
        \"enableSeasonFolders\": true,
        \"isDefault\": true,
        \"externalUrl\": \"\",
        \"syncEnabled\": true
    }"

    local response
    response=$(curl -s -X POST "${OVERSEERR_URL}/api/v1/settings/sonarr" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${overseerr_api_key}" \
        -d "$sonarr_config")

    if echo "$response" | grep -q '"id"'; then
        log_success "Sonarr added to Overseerr"
        return 0
    else
        log_error "Failed to add Sonarr to Overseerr"
        return 1
    fi
}

# Enable Plex watchlist sync in Overseerr
enable_overseerr_watchlist_sync() {
    local overseerr_api_key=$1

    log_info "Enabling Overseerr watchlist sync..."

    # Get current settings
    local current_settings
    current_settings=$(curl -s -H "X-Api-Key: ${overseerr_api_key}" \
        "${OVERSEERR_URL}/api/v1/settings/main")

    # Update with watchlist sync enabled
    local updated_settings
    updated_settings=$(echo "$current_settings" | \
        sed 's/"autoApproveMovie":[^,]*/"autoApproveMovie":true/' | \
        sed 's/"autoApproveSeries":[^,]*/"autoApproveSeries":true/')

    local response
    response=$(curl -s -X POST "${OVERSEERR_URL}/api/v1/settings/main" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${overseerr_api_key}" \
        -d "$updated_settings")

    if echo "$response" | grep -q '"autoApproveMovie":true'; then
        log_success "Watchlist sync enabled with auto-approval"
        return 0
    else
        log_error "Failed to enable watchlist sync"
        return 1
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    echo ""
    log_info "Checking for required tools..."

    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed. Please install it first."
        exit 1
    fi

    if ! command -v grep &> /dev/null; then
        log_error "grep is required but not installed. Please install it first."
        exit 1
    fi

    log_success "Required tools found"
    echo ""

    # Get config directory from environment or use default
    CONFIG_DIR="${CONFIG_DIR:-${DOCKER_CONFIG:-./configs}}"

    # Check if we should use local config files or wait for services
    if [ -f "${CONFIG_DIR}/radarr/config.xml" ]; then
        log_info "Found local config files, extracting API keys..."
        RADARR_API_KEY=$(get_arr_api_key "Radarr" "${CONFIG_DIR}/radarr/config.xml")
        SONARR_API_KEY=$(get_arr_api_key "Sonarr" "${CONFIG_DIR}/sonarr/config.xml")
        PROWLARR_API_KEY=$(get_arr_api_key "Prowlarr" "${CONFIG_DIR}/prowlarr/config.xml")
    else
        log_info "Waiting for services to generate configs..."

        # Wait for services to be ready
        wait_for_service "Radarr" "$RADARR_URL" "/api/v3/system/status"
        wait_for_service "Sonarr" "$SONARR_URL" "/api/v3/system/status"
        wait_for_service "Prowlarr" "$PROWLARR_URL" "/api/v1/system/status"
        wait_for_service "qBittorrent" "$QBITTORRENT_URL" "/"

        echo ""
        log_warn "Services are running but API keys need to be provided."
        echo ""
        read -rp "Enter Radarr API key (from Settings > General): " RADARR_API_KEY
        read -rp "Enter Sonarr API key (from Settings > General): " SONARR_API_KEY
        read -rp "Enter Prowlarr API key (from Settings > General): " PROWLARR_API_KEY
    fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}                    Configuring Download Clients${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Get qBittorrent password from logs if not provided.
    # Suppress set -e failure so a missing password doesn't abort the script;
    # the caller handles the empty-string case below.
    QB_PASSWORD=$(get_qbittorrent_password "${QBITTORRENT_CONTAINER:-qbittorrent}") || QB_PASSWORD=""
    if [ -z "$QB_PASSWORD" ]; then
        log_warn "Could not retrieve qBittorrent password automatically."
        log_info "Please check: docker logs ${QBITTORRENT_CONTAINER:-qbittorrent} 2>&1 | grep -i password"
        # Only prompt when running interactively; skip in CI / test mode.
        if [[ -t 0 ]]; then
            read -rp "Enter qBittorrent WebUI password: " QB_PASSWORD
        fi
    fi

    add_qbittorrent_to_radarr "$RADARR_API_KEY"
    add_qbittorrent_to_sonarr "$SONARR_API_KEY"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}                    Configuring Root Folders${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # When QBITTORRENT_CONTAINER is set, derive the arr container names from the same
    # Docker Compose project and pre-create the media directories inside those containers.
    # This is required in isolated test stacks where volumes are not pre-populated;
    # production deployments mount the directories via docker-compose, so this is a no-op.
    if [[ -n "${QBITTORRENT_CONTAINER:-}" ]]; then
        _arr_prefix="${QBITTORRENT_CONTAINER%-qbittorrent-1}"
        docker exec "${_arr_prefix}-radarr-1" \
            bash -c "mkdir -p '${MOVIES_PATH}' && chown abc:abc '${MOVIES_PATH}'" 2>/dev/null || true
        docker exec "${_arr_prefix}-sonarr-1" \
            bash -c "mkdir -p '${TV_PATH}' && chown abc:abc '${TV_PATH}'" 2>/dev/null || true
    fi

    add_radarr_root_folder "$RADARR_API_KEY"
    add_sonarr_root_folder "$SONARR_API_KEY"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}                    Configuring Prowlarr Connections${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    add_radarr_to_prowlarr "$PROWLARR_API_KEY" "$RADARR_API_KEY"
    add_sonarr_to_prowlarr "$PROWLARR_API_KEY" "$SONARR_API_KEY"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}                    Adding Public Indexers${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    add_public_indexers "$PROWLARR_API_KEY"

    echo ""
    log_info "Waiting 5 seconds for indexers to be added..."
    sleep 5

    sync_prowlarr_indexers "$PROWLARR_API_KEY"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}                    Configuring Overseerr${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    wait_for_service "Overseerr" "$OVERSEERR_URL" "/api/v1/status"

    if ! initialize_overseerr; then
        log_error "Overseerr is not initialized. Please sign in with your Plex account at $OVERSEERR_URL"
        overseerr_choice=""
        # Only prompt when running interactively; skip in CI / test mode.
        if [[ -t 0 ]]; then
            echo "Complete the Overseerr sign-in, then press Enter to continue."
            echo "Or type 'skip' to skip Overseerr configuration for now."
            read -rp "Continue: " overseerr_choice
        else
            log_warn "Skipping Overseerr configuration (non-interactive mode)"
        fi
        if [[ "$overseerr_choice" =~ ^(skip|s)$ ]]; then
            log_warn "Skipping Overseerr configuration"
        elif ! initialize_overseerr; then
            log_warn "Overseerr still not initialized. Skipping Overseerr configuration"
        fi
    fi

    if initialize_overseerr; then
        log_info "Overseerr is initialized, configuring services..."

        overseerr_api_key=$(get_overseerr_api_key)

        if [ -z "$overseerr_api_key" ]; then
            log_error "Could not retrieve Overseerr API key - skipping Overseerr configuration"
        else
            add_radarr_to_overseerr "$RADARR_API_KEY" "$overseerr_api_key"
            add_sonarr_to_overseerr "$SONARR_API_KEY" "$overseerr_api_key"
            enable_overseerr_watchlist_sync "$overseerr_api_key"

            log_success "Overseerr configuration complete!"
        fi
    fi

    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                    Configuration Complete! 🎉                          ║"
    echo "╠═══════════════════════════════════════════════════════════════════════╣"
    echo "║                                                                        ║"
    echo "║  Your services are now connected:                                      ║"
    echo "║                                                                        ║"
    echo "║  ✓ qBittorrent → Radarr/Sonarr (download client)                       ║"
    echo "║  ✓ Prowlarr → Radarr/Sonarr (indexer sync)                             ║"
    echo "║  ✓ Public indexers added to Prowlarr                                   ║"
    echo "║  ✓ Overseerr → Plex (watchlist monitoring)                             ║"
    echo "║  ✓ Overseerr → Radarr + Sonarr (auto-requests)                         ║"
    echo "║                                                                        ║"
    echo "║  Next Steps:                                                           ║"
    echo "║  1. Sign in to Overseerr with your Plex account                        ║"
    echo "║  2. Add a movie or show to your Plex watchlist                         ║"
    echo "║  3. Watch it automatically download and appear in your library!        ║"
    echo "║                                                                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Run main function
main "$@"
