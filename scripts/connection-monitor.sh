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

# Send refresh command to Chromium via Chrome DevTools Protocol
# This works on both X11 and Wayland (unlike xdotool which only works on X11)
refresh_chromium() {
    log "Attempting to refresh Chromium page..."

    # Method 1: Try Chrome DevTools Protocol (works on both X11 and Wayland)
    if pgrep -f "chromium.*remote-debugging-port" &>/dev/null; then
        local debug_url="http://localhost:$CHROMIUM_DEBUG_PORT/json"
        local pages=$(curl -s --max-time 2 "$debug_url" 2>/dev/null)

        if [ -n "$pages" ]; then
            # Get the page ID for sending commands
            local page_id=$(echo "$pages" | python3 -c "
import json, sys
try:
    pages = json.load(sys.stdin)
    for page in pages:
        if page.get('type') == 'page':
            print(page.get('id', ''))
            break
except:
    pass
" 2>/dev/null)

            if [ -n "$page_id" ]; then
                # Send Page.reload via HTTP endpoint (simpler than websocket)
                local reload_result=$(curl -s --max-time 5 \
                    "http://localhost:$CHROMIUM_DEBUG_PORT/json/activate/$page_id" 2>/dev/null)

                # Use Python to send the actual reload command via websocket
                python3 -c "
import json
import socket
import ssl

# Simple websocket to send CDP command
def send_cdp_command(ws_url, method, params=None):
    try:
        import urllib.request
        # Parse ws:// URL
        if ws_url.startswith('ws://'):
            host_port = ws_url[5:].split('/')[0]
            path = '/' + '/'.join(ws_url[5:].split('/')[1:])
            host, port = host_port.split(':') if ':' in host_port else (host_port, 80)
            port = int(port)

            # Create socket and send websocket upgrade
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(3)
            sock.connect((host, port))

            # Websocket handshake
            import hashlib, base64, os
            key = base64.b64encode(os.urandom(16)).decode()
            handshake = f'GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'
            sock.send(handshake.encode())
            response = sock.recv(1024)

            if b'101' in response:
                # Send reload command
                cmd = json.dumps({'id': 1, 'method': method, 'params': params or {}})
                frame = bytearray([0x81, len(cmd)]) + cmd.encode()
                sock.send(bytes(frame))
                sock.close()
                return True
    except:
        pass
    return False

# Get page ws URL
pages = json.loads('''$pages''')
for page in pages:
    if page.get('type') == 'page':
        ws_url = page.get('webSocketDebuggerUrl', '')
        if ws_url:
            if send_cdp_command(ws_url, 'Page.reload', {'ignoreCache': True}):
                print('reloaded')
                break
" 2>/dev/null

                if [ $? -eq 0 ]; then
                    log "Page reload sent via Chrome DevTools Protocol"
                    return 0
                fi
            fi
        fi
    fi

    # Method 2: Fallback - signal process manager to restart browser
    log "CDP refresh failed, falling back to process restart"
    if send_hup_to_process_manager; then
        log "Sent HUP signal to process manager"
        return 0
    fi

    log "Could not refresh page"
    return 1
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
