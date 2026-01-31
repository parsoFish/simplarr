#!/bin/bash
#===============================================================================
# Simplarr Pre-flight Validation Script (Bash)
# 
# This script checks your system is ready to run the Simplarr stack.
# Run this BEFORE running docker-compose to catch common issues early.
#
# Usage: ./preflight.sh [env-file]
#   env-file: Optional path to .env file (default: .env in current directory)
#
# Exit Codes:
#   0 - All checks passed
#   1 - Critical checks failed (stack won't work)
#   2 - Warnings only (stack may work but with issues)
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Symbols
CHECK="${GREEN}✓${NC}"
CROSS="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Environment file
ENV_FILE="${1:-.env}"

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_section() {
    echo ""
    echo -e "${BOLD}$1${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────────${NC}"
}

pass() {
    echo -e "  ${CHECK} $1"
    ((PASS_COUNT++))
}

fail() {
    echo -e "  ${CROSS} $1"
    echo -e "      ${YELLOW}→ Suggestion: $2${NC}"
    ((FAIL_COUNT++))
}

warn() {
    echo -e "  ${WARN} $1"
    echo -e "      ${YELLOW}→ Note: $2${NC}"
    ((WARN_COUNT++))
}

info() {
    echo -e "  ${INFO} $1"
}

# Check if a port is in use
check_port() {
    local port=$1
    local service=$2
    
    if command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":${port} "; then
            return 1
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":${port} "; then
            return 1
        fi
    elif command -v lsof &> /dev/null; then
        if lsof -i :${port} &> /dev/null; then
            return 1
        fi
    else
        echo -e "      ${YELLOW}(Unable to check port - no ss/netstat/lsof available)${NC}"
        return 0
    fi
    return 0
}

# Load environment variable from .env file
load_env_var() {
    local var_name=$1
    if [[ -f "$ENV_FILE" ]]; then
        local value=$(grep "^${var_name}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        echo "$value"
    fi
}

#-------------------------------------------------------------------------------
# Main Script
#-------------------------------------------------------------------------------

print_header "🚀 Simplarr Pre-flight Validation"

echo ""
echo -e "  ${INFO} Running pre-flight checks for Simplarr..."
echo -e "  ${INFO} Environment file: ${CYAN}${ENV_FILE}${NC}"
echo -e "  ${INFO} Date: $(date)"

#===============================================================================
# 1. DOCKER INSTALLATION CHECK
#===============================================================================
print_section "📦 Docker Installation"

# Check if Docker is installed
if command -v docker &> /dev/null; then
    pass "Docker is installed"
    
    # Get Docker version
    DOCKER_VERSION=$(docker --version 2>/dev/null | head -n1)
    info "Version: ${DOCKER_VERSION}"
    
    # Check if Docker daemon is running
    if docker info &> /dev/null; then
        pass "Docker daemon is running"
    else
        fail "Docker daemon is not running" "Start Docker Desktop or run 'sudo systemctl start docker'"
    fi
else
    fail "Docker is not installed" "Install Docker from https://docs.docker.com/get-docker/"
fi

# Check if Docker Compose is available
if docker compose version &> /dev/null; then
    pass "Docker Compose is available"
    COMPOSE_VERSION=$(docker compose version 2>/dev/null | head -n1)
    info "Version: ${COMPOSE_VERSION}"
elif command -v docker-compose &> /dev/null; then
    warn "Using legacy docker-compose" "Consider upgrading to Docker Compose V2 (docker compose)"
    COMPOSE_VERSION=$(docker-compose --version 2>/dev/null | head -n1)
    info "Version: ${COMPOSE_VERSION}"
else
    fail "Docker Compose is not available" "Install Docker Compose: https://docs.docker.com/compose/install/"
fi

#===============================================================================
# 2. ENVIRONMENT FILE CHECK
#===============================================================================
print_section "📋 Environment Configuration"

if [[ -f "$ENV_FILE" ]]; then
    pass "Environment file exists: ${ENV_FILE}"
    
    # Check for required variables
    REQUIRED_VARS=("DOCKER_CONFIG" "DOCKER_MEDIA" "PUID" "PGID" "TZ")
    PLACEHOLDER_VALUES=("your-" "change-me" "placeholder" "xxx" "CHANGEME")
    
    for var in "${REQUIRED_VARS[@]}"; do
        value=$(load_env_var "$var")
        if [[ -z "$value" ]]; then
            fail "${var} is not set" "Add ${var}=<value> to your ${ENV_FILE} file"
        else
            # Check for placeholder values
            is_placeholder=false
            for placeholder in "${PLACEHOLDER_VALUES[@]}"; do
                if [[ "$value" == *"$placeholder"* ]]; then
                    is_placeholder=true
                    break
                fi
            done
            
            if $is_placeholder; then
                fail "${var} contains placeholder value" "Replace the placeholder in ${ENV_FILE} with your actual value"
            else
                pass "${var} is configured"
                info "  Value: ${value}"
            fi
        fi
    done
else
    fail "Environment file not found: ${ENV_FILE}" "Copy .env.example to .env and configure your settings"
fi

#===============================================================================
# 3. PATH VALIDATION
#===============================================================================
print_section "📁 Path Validation"

DOCKER_CONFIG=$(load_env_var "DOCKER_CONFIG")
DOCKER_MEDIA=$(load_env_var "DOCKER_MEDIA")

# Check DOCKER_CONFIG path
if [[ -n "$DOCKER_CONFIG" ]]; then
    if [[ -d "$DOCKER_CONFIG" ]]; then
        pass "DOCKER_CONFIG directory exists: ${DOCKER_CONFIG}"
        
        # Check if writable
        if [[ -w "$DOCKER_CONFIG" ]]; then
            pass "DOCKER_CONFIG is writable"
        else
            fail "DOCKER_CONFIG is not writable" "Run: chmod -R u+w ${DOCKER_CONFIG} or check permissions"
        fi
    else
        warn "DOCKER_CONFIG directory doesn't exist: ${DOCKER_CONFIG}" "It will be created when containers start, but you may want to create it manually"
    fi
else
    info "DOCKER_CONFIG not set (skipping path check)"
fi

# Check DOCKER_MEDIA path
if [[ -n "$DOCKER_MEDIA" ]]; then
    if [[ -d "$DOCKER_MEDIA" ]]; then
        pass "DOCKER_MEDIA directory exists: ${DOCKER_MEDIA}"
        
        # Check for required subdirectories
        SUBDIRS=("movies" "tv" "downloads")
        for subdir in "${SUBDIRS[@]}"; do
            subpath="${DOCKER_MEDIA}/${subdir}"
            if [[ -d "$subpath" ]]; then
                pass "Subdirectory exists: ${subdir}/"
            else
                warn "Subdirectory missing: ${subdir}/" "Create it with: mkdir -p ${subpath}"
            fi
        done
    else
        fail "DOCKER_MEDIA directory doesn't exist: ${DOCKER_MEDIA}" "Create the directory or update the path in ${ENV_FILE}"
    fi
else
    info "DOCKER_MEDIA not set (skipping path check)"
fi

#===============================================================================
# 4. PORT AVAILABILITY CHECK
#===============================================================================
print_section "🔌 Port Availability"

# Define ports and their services
declare -A PORTS=(
    [80]="nginx (HTTP)"
    [443]="nginx (HTTPS)"
    [32400]="Plex Media Server"
    [8080]="qBittorrent WebUI"
    [7878]="Radarr"
    [8989]="Sonarr"
    [9696]="Prowlarr"
    [5055]="Overseerr"
    [8181]="Tautulli"
)

for port in "${!PORTS[@]}"; do
    service="${PORTS[$port]}"
    if check_port "$port" "$service"; then
        pass "Port ${port} is available (${service})"
    else
        fail "Port ${port} is in use (${service})" "Stop the service using this port or change the port mapping in docker-compose.yml"
    fi
done

#===============================================================================
# 5. NETWORK CONNECTIVITY CHECK
#===============================================================================
print_section "🌐 Network Connectivity"

# Check Docker Hub connectivity
info "Testing Docker Hub connectivity..."
if docker pull hello-world &> /dev/null; then
    pass "Can connect to Docker Hub"
    # Clean up the test image
    docker rmi hello-world &> /dev/null 2>&1 || true
else
    fail "Cannot connect to Docker Hub" "Check your internet connection and firewall settings"
fi

# Check general internet connectivity
if command -v ping &> /dev/null; then
    if ping -c 1 -W 3 8.8.8.8 &> /dev/null; then
        pass "Internet connectivity OK"
    else
        warn "Cannot reach external network" "Check your internet connection"
    fi
fi

#===============================================================================
# SUMMARY
#===============================================================================
print_header "📊 Summary"

TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

echo ""
echo -e "  ${GREEN}Passed:${NC}   ${PASS_COUNT}"
echo -e "  ${RED}Failed:${NC}   ${FAIL_COUNT}"
echo -e "  ${YELLOW}Warnings:${NC} ${WARN_COUNT}"
echo ""

if [[ $FAIL_COUNT -eq 0 ]] && [[ $WARN_COUNT -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}🎉 All checks passed! Your system is ready.${NC}"
    echo ""
    echo -e "  Next steps:"
    echo -e "    1. Review your ${ENV_FILE} settings"
    echo -e "    2. Run: ${CYAN}docker compose up -d${NC}"
    echo ""
    exit 0
elif [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}⚠️  Checks passed with warnings. Review the issues above.${NC}"
    echo ""
    echo -e "  The stack should work, but you may experience some issues."
    echo -e "  Consider fixing the warnings before proceeding."
    echo ""
    exit 2
else
    echo -e "  ${RED}${BOLD}❌ Critical issues found! Please fix them before proceeding.${NC}"
    echo ""
    echo -e "  The stack will NOT work correctly until these issues are resolved."
    echo -e "  Review the suggestions above for each failed check."
    echo ""
    exit 1
fi
