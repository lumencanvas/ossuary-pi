#!/bin/bash

# Ossuary Startup Manager
# Runs user-configured startup command after network connection
# Compatible with Pi OS Bookworm/Trixie (systemd 252+)

CONFIG_FILE="/etc/ossuary/config.json"
LOG_FILE="/var/log/ossuary-startup.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Wait for network connectivity
wait_for_network() {
    local max_attempts=12
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log "Network connectivity established"
            return 0
        fi
        log "Waiting for network... (attempt $((attempt+1))/$max_attempts)"
        sleep 5
        attempt=$((attempt+1))
    done

    log "Network timeout after $max_attempts attempts"
    return 1
}

# Read startup command from config
get_startup_command() {
    if [ -f "$CONFIG_FILE" ]; then
        # Extract startup_command from JSON (simple grep approach)
        grep -o '"startup_command"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | \
            sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
    fi
}

# Main execution
main() {
    log "Ossuary startup manager started"

    # Wait for network
    if ! wait_for_network; then
        log "Exiting due to network timeout"
        exit 1
    fi

    # Get and execute startup command
    STARTUP_CMD=$(get_startup_command)

    if [ -n "$STARTUP_CMD" ]; then
        log "Executing startup command: $STARTUP_CMD"

        # Try to run as pi user if it exists, otherwise as current user
        if id "pi" &>/dev/null; then
            su - pi -c "$STARTUP_CMD" 2>&1 | while read -r line; do
                log "CMD: $line"
            done &
            log "Startup command launched as user 'pi'"
        else
            $STARTUP_CMD 2>&1 | while read -r line; do
                log "CMD: $line"
            done &
            log "Startup command launched as current user"
        fi
    else
        log "No startup command configured"
    fi
}

# Run main function
main