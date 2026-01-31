#!/bin/bash

# =============================================================================
# Simplarr - Interactive Setup Script
# =============================================================================
# This script will help you configure your .env file for the media server stack
# Compatible with Linux, macOS, and WSL
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}  ${BOLD}${CYAN}Simplarr - Interactive Setup${NC}                                  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

print_hint() {
    echo -e "  ${YELLOW}💡 Hint:${NC} $1"
}

# Validate path exists or offer to create
validate_path() {
    local path="$1"
    local description="$2"
    
    if [[ -d "$path" ]]; then
        print_success "Path exists: $path"
        return 0
    else
        print_warning "Path does not exist: $path"
        read -p "  Would you like to create it? (y/n): " create_choice
        if [[ "$create_choice" =~ ^[Yy]$ ]]; then
            if mkdir -p "$path" 2>/dev/null; then
                print_success "Created directory: $path"
                return 0
            else
                print_error "Failed to create directory. Please check permissions."
                return 1
            fi
        else
            print_error "Path is required. Please create it manually and re-run setup."
            return 1
        fi
    fi
}

# Load existing values from .env if it exists
load_existing_env() {
    if [[ -f "$ENV_FILE" ]]; then
        print_info "Found existing .env file. Loading current values as defaults..."
        source "$ENV_FILE" 2>/dev/null
        return 0
    fi
    return 1
}

# =============================================================================
# Main Setup
# =============================================================================

print_header

# =============================================================================
# Setup Type Selection
# =============================================================================

print_section "Setup Type"

echo -e "  Choose your deployment type:"
echo ""
echo -e "  ${CYAN}1) Unified${NC} - All services on a single machine"
echo -e "     Best for: Dedicated server, powerful NAS, or testing"
echo ""
echo -e "  ${CYAN}2) Split${NC} - Services split across NAS + another device"
echo -e "     Best for: NAS handles Plex/downloads, Pi/server handles automation"
echo ""

while true; do
    read -p "  Select setup type (1 or 2) [1]: " setup_type_input
    setup_type_input="${setup_type_input:-1}"
    if [[ "$setup_type_input" == "1" ]]; then
        SETUP_TYPE="unified"
        print_success "Setup type: Unified (single machine)"
        break
    elif [[ "$setup_type_input" == "2" ]]; then
        SETUP_TYPE="split"
        print_success "Setup type: Split (NAS + separate device)"
        break
    else
        print_error "Please enter 1 or 2"
    fi
done

# For split setup, determine which device we're configuring
if [[ "$SETUP_TYPE" == "split" ]]; then
    echo ""
    echo -e "  Which device are you configuring?"
    echo ""
    echo -e "  ${CYAN}1) NAS${NC} - Will run Plex and qBittorrent"
    echo -e "  ${CYAN}2) Pi/Server${NC} - Will run Radarr, Sonarr, Prowlarr, etc."
    echo ""
    
    while true; do
        read -p "  Select device (1 or 2): " device_input
        if [[ "$device_input" == "1" ]]; then
            SPLIT_DEVICE="nas"
            print_success "Configuring: NAS (Plex + qBittorrent)"
            break
        elif [[ "$device_input" == "2" ]]; then
            SPLIT_DEVICE="pi"
            print_success "Configuring: Pi/Server (automation services)"
            break
        else
            print_error "Please enter 1 or 2"
        fi
    done
fi

# Check for existing .env
if [[ -f "$ENV_FILE" ]]; then
    echo -e "${YELLOW}An existing .env file was found.${NC}"
    read -p "Would you like to update it? (y/n): " update_choice
    if [[ ! "$update_choice" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Setup cancelled. Your existing .env file was not modified.${NC}"
        exit 0
    fi
    load_existing_env
    echo ""
fi

# =============================================================================
# PUID Configuration
# =============================================================================

print_section "User ID (PUID)"

echo -e "  The PUID is used to run containers as your user to avoid permission issues."
print_hint "Run ${BOLD}id -u${NC} in your terminal to find your user ID"

current_uid=$(id -u 2>/dev/null || echo "1000")
default_puid="${PUID:-$current_uid}"

echo ""
read -p "  Enter PUID [$default_puid]: " input_puid
PUID="${input_puid:-$default_puid}"
print_success "PUID set to: $PUID"

# =============================================================================
# PGID Configuration
# =============================================================================

print_section "Group ID (PGID)"

echo -e "  The PGID is used to run containers with your group permissions."
print_hint "Run ${BOLD}id -g${NC} in your terminal to find your group ID"

current_gid=$(id -g 2>/dev/null || echo "1000")
default_pgid="${PGID:-$current_gid}"

echo ""
read -p "  Enter PGID [$default_pgid]: " input_pgid
PGID="${input_pgid:-$default_pgid}"
print_success "PGID set to: $PGID"

# =============================================================================
# Timezone Configuration
# =============================================================================

print_section "Timezone (TZ)"

echo -e "  Set your timezone for proper scheduling and log timestamps."
echo ""
echo -e "  ${CYAN}Common examples:${NC}"
echo -e "    • America/New_York     • America/Los_Angeles"
echo -e "    • America/Chicago      • America/Denver"
echo -e "    • Europe/London        • Europe/Paris"
echo -e "    • Australia/Sydney     • Asia/Tokyo"
print_hint "Full list: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"

default_tz="${TZ:-America/New_York}"

echo ""
read -p "  Enter Timezone [$default_tz]: " input_tz
TZ="${input_tz:-$default_tz}"
print_success "Timezone set to: $TZ"

# =============================================================================
# Docker Config Path
# =============================================================================

print_section "Docker Config Path (DOCKER_CONFIG)"

echo -e "  This is where all your service configurations will be stored."
echo -e "  Each service (Plex, Sonarr, Radarr, etc.) will have its own subfolder."
print_hint "Example: /home/user/docker or /opt/docker-config"

default_config="${DOCKER_CONFIG:-}"

echo ""
read -p "  Enter config path${default_config:+ [$default_config]}: " input_config
DOCKER_CONFIG="${input_config:-$default_config}"

if [[ -z "$DOCKER_CONFIG" ]]; then
    print_error "Config path is required!"
    exit 1
fi

validate_path "$DOCKER_CONFIG" "config" || exit 1

# =============================================================================
# Docker Media Path
# =============================================================================

print_section "Docker Media Path (DOCKER_MEDIA)"

echo -e "  This is your main media library location."
echo -e "  It should contain (or will contain) these subdirectories:"
echo -e "    ${CYAN}movies/${NC}    - Your movie collection"
echo -e "    ${CYAN}tv/${NC}        - Your TV show collection"
echo -e "    ${CYAN}downloads/${NC} - Download client output"
print_hint "Example: /mnt/media or /home/user/media"

default_media="${DOCKER_MEDIA:-}"

echo ""
read -p "  Enter media path${default_media:+ [$default_media]}: " input_media
DOCKER_MEDIA="${input_media:-$default_media}"

if [[ -z "$DOCKER_MEDIA" ]]; then
    print_error "Media path is required!"
    exit 1
fi

validate_path "$DOCKER_MEDIA" "media" || exit 1

# Check/create subdirectories
echo ""
print_info "Checking media subdirectories..."
for subdir in movies tv downloads; do
    subpath="$DOCKER_MEDIA/$subdir"
    if [[ -d "$subpath" ]]; then
        print_success "Found: $subpath"
    else
        read -p "  Create $subdir directory? (y/n): " create_sub
        if [[ "$create_sub" =~ ^[Yy]$ ]]; then
            mkdir -p "$subpath" && print_success "Created: $subpath"
        fi
    fi
done

# =============================================================================
# Plex Claim Token
# =============================================================================

print_section "Plex Claim Token (PLEX_CLAIM)"

echo -e "  A claim token links this Plex server to your Plex account."
echo ""
echo -e "  ${YELLOW}${BOLD}⚠ IMPORTANT: Claim tokens expire in 4 minutes!${NC}"
echo ""
echo -e "  ${CYAN}Steps:${NC}"
echo -e "    1. Go to: ${BOLD}https://plex.tv/claim${NC}"
echo -e "    2. Sign in to your Plex account"
echo -e "    3. Copy the token (starts with 'claim-')"
echo -e "    4. Paste it here immediately"
echo ""
print_hint "You can leave this blank and add it later to .env before first run"

default_claim="${PLEX_CLAIM:-}"

echo ""
read -p "  Enter Plex Claim Token (or press Enter to skip): " input_claim
PLEX_CLAIM="${input_claim:-$default_claim}"

if [[ -n "$PLEX_CLAIM" ]]; then
    if [[ "$PLEX_CLAIM" == claim-* ]]; then
        print_success "Plex claim token set"
    else
        print_warning "Token doesn't start with 'claim-' - please verify it's correct"
    fi
else
    print_warning "No claim token set. Remember to add it before starting Plex!"
fi

# =============================================================================
# NAS IP Configuration (Split Setup Only)
# =============================================================================

if [[ "$SETUP_TYPE" == "split" && "$SPLIT_DEVICE" == "pi" ]]; then
    print_section "NAS IP Address"
    
    echo -e "  Enter the IP address of your NAS."
    echo -e "  This is needed so the reverse proxy can reach Plex and qBittorrent."
    print_hint "Example: 192.168.1.100 or 10.0.0.50"
    
    echo ""
    while true; do
        read -p "  Enter NAS IP address: " NAS_IP
        # Basic IP validation
        if [[ "$NAS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            print_success "NAS IP set to: $NAS_IP"
            break
        else
            print_error "Please enter a valid IP address (e.g., 192.168.1.100)"
        fi
    done
fi

# =============================================================================
# Summary
# =============================================================================

print_section "Configuration Summary"

echo ""
echo -e "  ${BOLD}Setup Type:${NC}    $SETUP_TYPE${SPLIT_DEVICE:+ ($SPLIT_DEVICE)}"
echo -e "  ${BOLD}PUID:${NC}          $PUID"
echo -e "  ${BOLD}PGID:${NC}          $PGID"
echo -e "  ${BOLD}TZ:${NC}            $TZ"
echo -e "  ${BOLD}DOCKER_CONFIG:${NC} $DOCKER_CONFIG"
echo -e "  ${BOLD}DOCKER_MEDIA:${NC}  $DOCKER_MEDIA"
echo -e "  ${BOLD}PLEX_CLAIM:${NC}    ${PLEX_CLAIM:-<not set>}"
if [[ -n "$NAS_IP" ]]; then
    echo -e "  ${BOLD}NAS_IP:${NC}        $NAS_IP"
fi
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
read -p "  Save this configuration to .env? (y/n): " save_choice

if [[ ! "$save_choice" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Setup cancelled. No changes were made.${NC}"
    exit 0
fi

# =============================================================================
# Write .env File
# =============================================================================

# Backup existing file
if [[ -f "$ENV_FILE" ]]; then
    backup_file="$ENV_FILE.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$ENV_FILE" "$backup_file"
    print_info "Backed up existing .env to: $(basename "$backup_file")"
fi

# Write new .env file
cat > "$ENV_FILE" << EOF
# =============================================================================
# Simplarr - Environment Configuration
# Generated by setup.sh on $(date)
# =============================================================================

# User/Group IDs - Run 'id -u' and 'id -g' to find yours
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
EOF

echo ""
print_success "Configuration saved to: $ENV_FILE"

# =============================================================================
# Create Service Config Directories & Deploy Templates
# =============================================================================

print_section "Setting Up Service Configurations"

# Create config subdirectories
services=(plex radarr sonarr prowlarr qbittorrent overseerr tautulli nginx homepage)
for service in "${services[@]}"; do
    service_path="$DOCKER_CONFIG/$service"
    if [[ ! -d "$service_path" ]]; then
        mkdir -p "$service_path"
        print_success "Created: $service_path"
    fi
done

# Create qBittorrent subdirectory structure
mkdir -p "$DOCKER_CONFIG/qbittorrent/qBittorrent" 2>/dev/null

# Deploy qBittorrent pre-configured template
QBIT_TEMPLATE="$SCRIPT_DIR/templates/qBittorrent/qBittorrent.conf"
QBIT_CONFIG="$DOCKER_CONFIG/qbittorrent/qBittorrent/qBittorrent.conf"

if [[ -f "$QBIT_TEMPLATE" ]]; then
    if [[ ! -f "$QBIT_CONFIG" ]]; then
        cp "$QBIT_TEMPLATE" "$QBIT_CONFIG"
        print_success "Deployed qBittorrent pre-configured template"
        print_info "  → Auto-add trackers: ENABLED (public tracker list)"
        print_info "  → Download path: /downloads"
        print_info "  → Incomplete path: /downloads/incomplete"
        print_info "  → Max active downloads: 50"
        print_info "  → DHT/PeX/LSD: ENABLED"
    else
        print_warning "qBittorrent config already exists, skipping template deployment"
        print_hint "Delete $QBIT_CONFIG to use the template on next setup"
    fi
else
    print_warning "qBittorrent template not found at: $QBIT_TEMPLATE"
fi

# Create incomplete downloads directory
mkdir -p "$DOCKER_MEDIA/downloads/incomplete" 2>/dev/null
print_success "Created incomplete downloads directory"

# =============================================================================
# Update Nginx Config (Split Setup Only)
# =============================================================================

if [[ "$SETUP_TYPE" == "split" && "$SPLIT_DEVICE" == "pi" && -n "$NAS_IP" ]]; then
    SPLIT_CONF="$SCRIPT_DIR/nginx/split.conf"
    if [[ -f "$SPLIT_CONF" ]]; then
        # Replace YOUR_NAS_IP placeholder with actual IP
        sed -i "s/YOUR_NAS_IP/$NAS_IP/g" "$SPLIT_CONF"
        print_success "Updated nginx/split.conf with NAS IP: $NAS_IP"
    else
        print_warning "nginx/split.conf not found - you may need to update it manually"
    fi
fi

# =============================================================================
# Next Steps
# =============================================================================

print_section "Next Steps"

echo ""

if [[ "$SETUP_TYPE" == "unified" ]]; then
    # Unified setup instructions
    echo -e "  ${GREEN}1.${NC} Review your .env file: ${BOLD}cat .env${NC}"
    echo -e "  ${GREEN}2.${NC} Start your stack: ${BOLD}docker compose -f docker-compose-unified.yml up -d${NC}"
    echo -e "  ${GREEN}3.${NC} Wait for containers to be healthy: ${BOLD}docker compose -f docker-compose-unified.yml ps${NC}"
    echo -e "  ${GREEN}4.${NC} Run auto-configure: ${BOLD}./configure.sh${NC}"
    echo ""
    echo -e "  ${CYAN}Access your services:${NC}"
    echo -e "       • Plex:        http://localhost:32400/web"
    echo -e "       • Radarr:      http://localhost:7878"
    echo -e "       • Sonarr:      http://localhost:8989"
    echo -e "       • Prowlarr:    http://localhost:9696"
    echo -e "       • qBittorrent: http://localhost:8080"
    echo -e "       • Overseerr:   http://localhost:5055"
    echo ""
    echo -e "  ${YELLOW}qBittorrent Note:${NC}"
    echo -e "       Check container logs for initial password:"
    echo -e "       ${BOLD}docker logs qbittorrent 2>&1 | grep -i password${NC}"
elif [[ "$SETUP_TYPE" == "split" && "$SPLIT_DEVICE" == "nas" ]]; then
    # Split NAS setup instructions
    echo -e "  ${GREEN}1.${NC} Review your .env file: ${BOLD}cat .env${NC}"
    echo -e "  ${GREEN}2.${NC} Start NAS services: ${BOLD}docker compose -f docker-compose-nas.yml up -d${NC}"
    echo -e "  ${GREEN}3.${NC} Wait for containers to be healthy: ${BOLD}docker compose -f docker-compose-nas.yml ps${NC}"
    echo ""
    echo -e "  ${CYAN}NAS Services (local access):${NC}"
    echo -e "       • Plex:        http://localhost:32400/web"
    echo -e "       • qBittorrent: http://localhost:8080"
    echo ""
    echo -e "  ${YELLOW}qBittorrent Note:${NC}"
    echo -e "       Check container logs for initial password:"
    echo -e "       ${BOLD}docker logs qbittorrent 2>&1 | grep -i password${NC}"
    echo ""
    echo -e "  ${YELLOW}Next:${NC} Run setup.sh on your Pi/Server to set up the remaining services."
elif [[ "$SETUP_TYPE" == "split" && "$SPLIT_DEVICE" == "pi" ]]; then
    # Split Pi/Server setup instructions
    echo -e "  ${GREEN}1.${NC} Review your .env file: ${BOLD}cat .env${NC}"
    echo -e "  ${GREEN}2.${NC} Start Pi/Server services: ${BOLD}docker compose -f docker-compose-pi.yml up -d${NC}"
    echo -e "  ${GREEN}3.${NC} Wait for containers to be healthy: ${BOLD}docker compose -f docker-compose-pi.yml ps${NC}"
    echo -e "  ${GREEN}4.${NC} Run auto-configure: ${BOLD}./configure.sh${NC}"
    echo ""
    echo -e "  ${CYAN}Pi/Server Services (via Nginx at :80):${NC}"
    echo -e "       • Homepage:   http://localhost/"
    echo -e "       • Plex:       http://localhost/plex  → NAS ($NAS_IP)"
    echo -e "       • Radarr:     http://localhost/radarr"
    echo -e "       • Sonarr:     http://localhost/sonarr"
    echo -e "       • Prowlarr:   http://localhost/prowlarr"
    echo -e "       • qBittorrent: http://localhost/qbittorrent → NAS ($NAS_IP)"
    echo -e "       • Overseerr:  http://localhost/overseerr"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} Make sure your NAS services are running!"
    echo -e "  ${YELLOW}Note:${NC} nginx/split.conf has been configured with NAS IP: $NAS_IP"
fi

echo ""
echo -e "${GREEN}${BOLD}Setup complete! Happy streaming! 🎬${NC}"
echo ""
