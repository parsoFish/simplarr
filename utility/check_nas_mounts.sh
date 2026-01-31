#!/bin/bash

# =============================================================================
# NAS Monitoring and Auto-remount Script (Optional Utility)
# =============================================================================
# PURPOSE:
#   This script monitors NAS availability and automatically remounts shares
#   if they become disconnected. Useful for split setups (NAS + Pi) where
#   network interruptions can cause mount failures.
#
# WHAT IT DOES:
#   1. Pings the NAS to verify network connectivity
#   2. Checks if NAS mounts in /etc/fstab are actually mounted
#   3. Attempts to remount if any are disconnected
#   4. Sends email alerts if remount fails
#   5. Restarts Docker containers after successful remount
#
# WHEN TO USE:
#   - Split setup with NFS mounts from NAS
#   - Frequent network interruptions
#   - Want automatic recovery without manual intervention
#
# SETUP REQUIRED:
#   1. Edit the Configuration section below with your values
#   2. Install msmtp for email notifications: sudo apt install msmtp msmtp-mta
#   3. Configure msmtp: Create ~/.msmtprc with your email settings
#   4. Make executable: chmod +x check_nas_mounts.sh
#   5. Test manually: ./check_nas_mounts.sh
#   6. Add to crontab for automatic monitoring
#
# EXAMPLE CRONTAB (check every 5 minutes):
#   */5 * * * * /path/to/check_nas_mounts.sh
#
# ALTERNATIVE: Use systemd timer for more control over scheduling
#
# =============================================================================

# Configuration - UPDATE THESE VALUES BEFORE USE
NAS_IP="YOUR_NAS_IP"                    # Your NAS IP, e.g., 192.168.1.100
EMAIL="your.email@example.com"          # Where to send alerts (requires msmtp)
LOG_FILE="$HOME/nas_monitor.log"        # Log file location
DOCKER_COMPOSE_DIR="$HOME/simplarr"     # Path to your simplarr directory

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to send email notification
send_email() {
    local subject="$1"
    local message="$2"

    echo -e "Subject: $subject\n\n$message" | msmtp "$EMAIL"
    log_message "Email sent: $subject"
}

# Check if NAS is reachable on the network
log_message "Starting NAS check..."

if ! ping -c 3 -W 5 "$NAS_IP" > /dev/null 2>&1; then
    log_message "ERROR: NAS at $NAS_IP is not reachable on the network!"
    send_email "NAS Alert: Network Unreachable" \
        "The NAS at $NAS_IP is not responding to ping requests.\n\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nPlease check the NAS connection."
    exit 1
fi

log_message "NAS is reachable on the network"

# Check mounted filesystems
# Get list of NAS mounts from fstab (grep for NAS IP or common NAS mount indicators)
NAS_MOUNTS=$(grep -E "^$NAS_IP|^//.*$NAS_IP" /etc/fstab | awk '{print $2}')

if [ -z "$NAS_MOUNTS" ]; then
    log_message "WARNING: No NAS mounts found in /etc/fstab"
    exit 0
fi

# Check each mount point
REMOUNT_NEEDED=false
FAILED_MOUNTS=""

while IFS= read -r mount_point; do
    if mountpoint -q "$mount_point"; then
        log_message "Mount OK: $mount_point"
    else
        log_message "Mount FAILED: $mount_point - attempting remount"
        REMOUNT_NEEDED=true
        FAILED_MOUNTS+="$mount_point "
    fi
done <<< "$NAS_MOUNTS"

# Attempt to remount if needed
if [ "$REMOUNT_NEEDED" = true ]; then
    log_message "Attempting to remount failed mounts..."

    # Try to mount all entries from fstab
    mount -a 2>&1 | tee -a "$LOG_FILE"

    # Verify remount success
    sleep 2
    STILL_FAILED=""

    for mount_point in $FAILED_MOUNTS; do
        if mountpoint -q "$mount_point"; then
            log_message "Remount SUCCESS: $mount_point"
        else
            log_message "Remount FAILED: $mount_point"
            STILL_FAILED+="$mount_point "
        fi
    done

    # Send email if remount failed
    if [ -n "$STILL_FAILED" ]; then
        send_email "NAS Alert: Mount Failure" \
            "Failed to remount the following NAS shares:\n\n$STILL_FAILED\n\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nPlease check the system manually."
    else
        log_message "All mounts successfully restored"

        # Restart Docker containers that depend on the mounts
        log_message "Restarting Docker containers to refresh mount connections..."
        cd "$DOCKER_COMPOSE_DIR"
        docker-compose down 2>&1 | tee -a "$LOG_FILE"
        sleep 3
        docker-compose up -d 2>&1 | tee -a "$LOG_FILE"
        log_message "Docker containers restarted successfully"
    fi
else
    log_message "All NAS mounts are healthy"
fi

log_message "NAS check completed successfully"
exit 0