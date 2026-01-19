#!/bin/bash

# Ossuary Connection Monitor
# Monitors network connectivity and triggers actions on connection events

CONFIG_FILE="/etc/ossuary/config.json"
LOG_FILE="/var/log/ossuary-connection.log"
STATE_FILE="/run/ossuary/connection-state"
CHROMIUM_DEBUG_PORT=9222

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$STATE_FILE")"

# Initialize state
LAST_STATE="unknown"
DISCONNECTED_SINCE=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if connected to internet
check_connection() {
    # Try multiple endpoints for reliability
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        echo "connected"
        return
    fi
    if ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
        echo "connected"
        return
    fi
    # Check if we at least have a gateway
    local gateway
    gateway=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1)
    if [ -n "$gateway" ] && ping -c 1 -W 2 "$gateway" &>/dev/null; then
        echo "connected"
        return
    fi
    echo "disconnected"
}

# Get behavior settings from config
get_behavior() {
    local key="$1"
    if [ -f "$CONFIG_FILE" ]; then
        python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        config = json.load(f)
        behaviors = config.get('behaviors', {})
        value = behaviors.get('$key', {})
        if isinstance(value, dict):
            action = value.get('action', '')
            print(action)
        elif isinstance(value, bool):
            print('enabled' if value else 'disabled')
        else:
            print(value)
except:
    pass
" 2>/dev/null
    fi
}

# Check if refresh interval is enabled and get minutes
get_refresh_interval() {
    if [ -f "$CONFIG_FILE" ]; then
        python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        config = json.load(f)
        refresh = config.get('behaviors', {}).get('scheduled_refresh', {})
        if refresh.get('enabled', False):
            print(refresh.get('interval_minutes', 60))
        else:
            print(0)
except:
    print(0)
" 2>/dev/null
    else
        echo 0
    fi
}

# Send SIGHUP to process manager safely
send_hup_to_process_manager() {
    local pid_file="/run/ossuary/process.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -HUP "$pid" 2>/dev/null
            return 0
        fi
    fi
    return 1
}

# Send refresh command to Chromium via remote debugging
refresh_chromium() {
    log "Attempting to refresh Chromium page..."

    # Check if Chromium is running with remote debugging
    if ! pgrep -f "chromium.*remote-debugging-port" &>/dev/null; then
        log "Chromium not running with remote debugging, sending SIGHUP to process manager"
        send_hup_to_process_manager
        return
    fi

    # Try to send reload command via Chrome DevTools Protocol
    # Get the first page's websocket URL
    local debug_url="http://localhost:$CHROMIUM_DEBUG_PORT/json"

    # Use curl to get the page list
    local pages=$(curl -s "$debug_url" 2>/dev/null)

    if [ -z "$pages" ]; then
        log "Could not connect to Chromium debug port"
        return
    fi

    # Extract the first page's webSocketDebuggerUrl
    local ws_url=$(echo "$pages" | python3 -c "
import json, sys
try:
    pages = json.load(sys.stdin)
    if pages and len(pages) > 0:
        print(pages[0].get('webSocketDebuggerUrl', ''))
except:
    pass
" 2>/dev/null)

    if [ -n "$ws_url" ]; then
        # Use websocat or python to send reload command
        # For simplicity, we'll use curl with a simple HTTP endpoint approach
        # The Page.reload command needs websocket, so we'll use a simpler method

        # Alternative: Kill and let process manager restart
        log "Triggering page refresh via process restart..."
        if send_hup_to_process_manager; then
            log "Sent HUP signal to process manager"
        fi
    else
        log "No debug URL available"
    fi
}

# Handle connection lost
on_connection_lost() {
    log "Connection lost!"
    echo "disconnected" > "$STATE_FILE"
    DISCONNECTED_SINCE=$(date +%s)

    local action=$(get_behavior "on_connection_lost")
    log "Connection lost action: $action"

    case "$action" in
        "show_overlay")
            # Could inject an overlay via JavaScript if using remote debugging
            log "Would show overlay (not implemented yet)"
            ;;
        "pause")
            log "Pausing - waiting for reconnection"
            ;;
        "refresh")
            # Will refresh when connection returns
            ;;
        *)
            log "No action configured for connection lost"
            ;;
    esac
}

# Handle connection regained
on_connection_regained() {
    log "Connection regained!"
    echo "connected" > "$STATE_FILE"

    local action=$(get_behavior "on_connection_regained")
    log "Connection regained action: $action"

    case "$action" in
        "refresh_page"|"refresh")
            # Wait a moment for network to stabilize
            sleep 3
            refresh_chromium
            ;;
        "restart")
            log "Restarting process..."
            send_hup_to_process_manager
            ;;
        "continue"|"")
            log "Continuing without action"
            ;;
        *)
            log "Unknown action: $action"
            ;;
    esac

    DISCONNECTED_SINCE=0
}

# Main monitoring loop
main() {
    log "==================================="
    log "Connection Monitor started"
    log "==================================="

    local current_state
    local check_interval=5
    local last_refresh_time=$(date +%s)

    # Load initial state
    if [ -f "$STATE_FILE" ]; then
        LAST_STATE=$(cat "$STATE_FILE")
    fi

    while true; do
        current_state=$(check_connection)

        # State change detection
        if [ "$current_state" != "$LAST_STATE" ]; then
            if [ "$current_state" = "disconnected" ]; then
                on_connection_lost
            elif [ "$current_state" = "connected" ] && [ "$LAST_STATE" = "disconnected" ]; then
                on_connection_regained
            fi
            LAST_STATE="$current_state"
        fi

        # Scheduled refresh check (only when connected)
        if [ "$current_state" = "connected" ]; then
            local interval_mins
            interval_mins=$(get_refresh_interval)
            # Validate interval is a positive integer
            if [ -n "$interval_mins" ] && [ "$interval_mins" -eq "$interval_mins" ] 2>/dev/null && [ "$interval_mins" -gt 0 ]; then
                local interval_secs=$((interval_mins * 60))
                local now=$(date +%s)
                local elapsed=$((now - last_refresh_time))

                if [ $elapsed -ge $interval_secs ]; then
                    log "Scheduled refresh triggered (every ${interval_mins} minutes)"
                    refresh_chromium
                    last_refresh_time=$now
                fi
            fi
        fi

        sleep $check_interval
    done
}

# Signal handlers
trap 'log "Received TERM signal, stopping..."; exit 0' TERM INT

# Run main
main
