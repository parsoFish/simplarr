#!/bin/bash

# =============================================================================
# NAS Monitoring and Auto-remount Script (Optional Utility)
# =============================================================================
# PURPOSE:
#   Monitors NAS availability for split setups (NAS + Pi), remounts shares
#   that dropped, and — critically — detects the boot-order race where Docker
#   started BEFORE the NFS mounts came up. In that case containers are bound
#   to the empty local directories under the mountpoints: the host looks
#   healthy, but inside the containers /tv, /movies and /downloads are empty.
#
# WHAT IT DOES:
#   1. Pings the NAS to verify network connectivity
#   2. Checks that every NAS mount in /etc/fstab is mounted on the host
#   3. Remounts any that are missing
#   4. Compares the filesystem device seen INSIDE each container against the
#      device of the host mount; a mismatch means the container was started
#      before the mount and is looking at the SD card
#   5. Restarts the compose stack when a remount or mismatch was detected
#   6. Sends email alerts (msmtp) when recovery fails
#
# PREVENTION (do this too — the check is a safety net, not the fix):
#   /etc/fstab options:  nfs _netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=60 0 0
#   /etc/systemd/system/docker.service.d/10-nfs.conf:
#     [Unit]
#     After=network-online.target remote-fs.target
#     RequiresMountsFor=/mnt/nas/tv /mnt/nas/movies /mnt/nas/downloads
#
# SETUP REQUIRED:
#   1. Edit the Configuration section below
#   2. Install msmtp: sudo apt install msmtp msmtp-mta ; configure ~/.msmtprc
#   3. chmod +x check_nas_mounts.sh ; ./check_nas_mounts.sh
#   4. Crontab, e.g. every 15 minutes:  */15 * * * * /path/to/check_nas_mounts.sh
# =============================================================================

# Configuration - UPDATE THESE VALUES BEFORE USE
NAS_IP="YOUR_NAS_IP"                       # Your NAS IP, e.g., 192.168.1.100
EMAIL="your.email@example.com"             # Where to send alerts (requires msmtp)
LOG_FILE="$HOME/nas_monitor.log"           # Log file location
DOCKER_COMPOSE_DIR="$HOME/simplarr"        # Path to your simplarr checkout
COMPOSE_FILE="docker-compose-pi.yml"       # Compose file for this host
ENV_FILE=".env"                            # Env file for compose
# container:container_path=host_mount pairs to verify from inside containers
CONTAINER_MOUNTS=(
    "sonarr:/tv=/mnt/nas/tv"
    "sonarr:/downloads=/mnt/nas/downloads"
    "radarr:/movies=/mnt/nas/movies"
    "radarr:/downloads=/mnt/nas/downloads"
    "tautulli:/tv=/mnt/nas/tv"
)

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

send_email() {
    local subject="$1"
    local message="$2"
    echo -e "Subject: $subject\n\n$message" | msmtp "$EMAIL"
    log_message "Email sent: $subject"
}

restart_stack() {
    log_message "Restarting compose stack to re-bind NAS mounts..."
    cd "$DOCKER_COMPOSE_DIR" || { log_message "ERROR: cannot cd to $DOCKER_COMPOSE_DIR"; return 1; }
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down 2>&1 | tee -a "$LOG_FILE"
    sleep 3
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1 | tee -a "$LOG_FILE"
    log_message "Compose stack restarted"
}

# Device number of a path as seen by a container (empty if container is down)
container_device() {
    local container="$1" path="$2"
    docker exec "$container" stat -c %d "$path" 2>/dev/null
}

log_message "Starting NAS check..."

if ! ping -c 3 -W 5 "$NAS_IP" > /dev/null 2>&1; then
    log_message "ERROR: NAS at $NAS_IP is not reachable on the network!"
    send_email "NAS Alert: Network Unreachable" \
        "The NAS at $NAS_IP is not responding to ping requests.\n\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nPlease check the NAS connection."
    exit 1
fi
log_message "NAS is reachable on the network"

# --- 1. Host mounts ----------------------------------------------------------
NAS_MOUNTS=$(grep -E "^$NAS_IP|^//.*$NAS_IP" /etc/fstab | awk '{print $2}')
if [ -z "$NAS_MOUNTS" ]; then
    log_message "WARNING: No NAS mounts found in /etc/fstab"
    exit 0
fi

RESTART_NEEDED=false
FAILED_MOUNTS=""
while IFS= read -r mount_point; do
    # Touching the path triggers systemd automount if configured
    ls "$mount_point" > /dev/null 2>&1
    if mountpoint -q "$mount_point"; then
        log_message "Mount OK: $mount_point"
    else
        log_message "Mount FAILED: $mount_point - attempting remount"
        RESTART_NEEDED=true
        FAILED_MOUNTS+="$mount_point "
    fi
done <<< "$NAS_MOUNTS"

if [ -n "$FAILED_MOUNTS" ]; then
    sudo mount -a 2>&1 | tee -a "$LOG_FILE"
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
    if [ -n "$STILL_FAILED" ]; then
        send_email "NAS Alert: Mount Failure" \
            "Failed to remount the following NAS shares:\n\n$STILL_FAILED\n\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nPlease check the system manually."
        exit 1
    fi
fi

# --- 2. Container view vs host view -----------------------------------------
MISMATCHED=""
for spec in "${CONTAINER_MOUNTS[@]}"; do
    container="${spec%%:*}"
    rest="${spec#*:}"
    cpath="${rest%%=*}"
    hpath="${rest#*=}"
    if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
        log_message "Container view: $container not running, skipping"
        continue
    fi
    hdev=$(stat -c %d "$hpath" 2>/dev/null)
    cdev=$(container_device "$container" "$cpath")
    if [ -z "$cdev" ] || [ "$cdev" != "$hdev" ]; then
        log_message "Container view MISMATCH: $container:$cpath dev=${cdev:-none} host $hpath dev=$hdev"
        MISMATCHED+="$container:$cpath "
        RESTART_NEEDED=true
    else
        log_message "Container view OK: $container:$cpath"
    fi
done

# --- 3. Recover --------------------------------------------------------------
if [ "$RESTART_NEEDED" = true ]; then
    restart_stack
    sleep 20
    STILL_BAD=""
    for spec in "${CONTAINER_MOUNTS[@]}"; do
        container="${spec%%:*}"; rest="${spec#*:}"; cpath="${rest%%=*}"; hpath="${rest#*=}"
        [ "$(container_device "$container" "$cpath")" = "$(stat -c %d "$hpath")" ] || STILL_BAD+="$container:$cpath "
    done
    if [ -n "$STILL_BAD" ]; then
        send_email "NAS Alert: Containers still not seeing NAS mounts" \
            "After a compose restart these container paths still do not match the host NFS mounts:\n\n$STILL_BAD\n\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        exit 1
    fi
    send_email "NAS Recovered: compose stack restarted" \
        "Trigger: mounts=[$FAILED_MOUNTS] container-mismatch=[$MISMATCHED]\n\nAll container paths now match the host NFS mounts.\n\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"
else
    log_message "All NAS mounts healthy (host and container views agree)"
fi

log_message "NAS check completed successfully"
exit 0
