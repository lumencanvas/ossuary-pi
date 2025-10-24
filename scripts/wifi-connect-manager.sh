#!/bin/bash

# WiFi Connect Manager
# Intelligently manages when to run WiFi Connect captive portal
# Only starts AP mode when no WiFi connection is available

CONFIG_FILE="/etc/ossuary/config.json"
LOG_FILE="/var/log/wifi-connect-manager.log"
CHECK_INTERVAL=30  # Check every 30 seconds
MAX_WAIT_FOR_NETWORK=180  # Wait up to 3 minutes for network on boot
INITIAL_WAIT=15  # Wait 15 seconds before first check to let NetworkManager initialize

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if we have a working internet connection
has_internet() {
    # Try multiple methods to detect internet connectivity

    # Method 1: Check if we can reach a reliable DNS server
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        return 0
    fi

    # Method 2: Check if we can reach Cloudflare DNS
    if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        return 0
    fi

    # Method 3: Try HTTP connectivity test
    if curl -s --max-time 5 http://detectportal.firefox.com/canonical.html >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Check if we have WiFi connection (not necessarily internet)
has_wifi_connection() {
    # Check if any WiFi interface is connected
    if iwgetid -r >/dev/null 2>&1; then
        local ssid=$(iwgetid -r)
        if [ -n "$ssid" ]; then
            log "Connected to WiFi: $ssid"
            return 0
        fi
    fi

    # Alternative check using NetworkManager
    if command -v nmcli >/dev/null; then
        if nmcli -t -f WIFI g status 2>/dev/null | grep -q "enabled"; then
            if nmcli -t -f STATE,CONNECTION device status 2>/dev/null | grep "wifi" | grep -q "connected"; then
                return 0
            fi
        fi
    fi

    return 1
}

# Check if there are saved WiFi networks
has_saved_networks() {
    if command -v nmcli >/dev/null; then
        # List all saved WiFi connections
        local saved_count=$(nmcli -t -f TYPE,NAME connection show 2>/dev/null | grep -c "^802-11-wireless:")
        if [ "$saved_count" -gt 0 ]; then
            log "Found $saved_count saved WiFi network(s)"
            return 0
        fi
    fi

    # Also check wpa_supplicant if NetworkManager isn't available
    if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        if grep -q "^[[:space:]]*ssid=" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
            log "Found saved networks in wpa_supplicant.conf"
            return 0
        fi
    fi

    return 1
}

# Try to connect to saved networks
try_connect_saved_networks() {
    if command -v nmcli >/dev/null; then
        log "Attempting to connect to saved networks..."

        # First ensure WiFi is enabled
        nmcli radio wifi on 2>/dev/null || true
        sleep 1

        # Get list of available WiFi networks
        nmcli device wifi rescan 2>/dev/null || true
        sleep 3

        # Get list of available SSIDs
        local available_ssids=$(nmcli -t -f SSID device wifi list 2>/dev/null | sort -u)

        # Try to connect to each saved network that's available
        for conn in $(nmcli -t -f TYPE,NAME connection show 2>/dev/null | grep "^802-11-wireless:" | cut -d: -f2); do
            # Get the SSID for this connection
            local conn_ssid=$(nmcli -t -f 802-11-wireless.ssid connection show "$conn" 2>/dev/null | cut -d: -f2)

            # Check if this network is available
            if echo "$available_ssids" | grep -q "^$conn_ssid$"; then
                log "Attempting to connect to saved network: $conn (SSID: $conn_ssid)"
                if nmcli connection up "$conn" 2>/dev/null; then
                    log "Successfully connected to $conn"
                    sleep 3
                    if has_wifi_connection; then
                        return 0
                    fi
                else
                    log "Failed to connect to $conn"
                fi
            fi
        done

        # If no specific connections worked, try auto-connect
        log "Trying NetworkManager auto-connect..."
        nmcli device connect wlan0 2>/dev/null || true
        sleep 5

        if has_wifi_connection; then
            return 0
        fi
    fi

    return 1
}

# Ensure saved networks have autoconnect enabled
ensure_autoconnect() {
    if command -v nmcli >/dev/null; then
        # Enable autoconnect for all WiFi connections
        for conn in $(nmcli -t -f TYPE,NAME connection show 2>/dev/null | grep "^802-11-wireless:" | cut -d: -f2); do
            log "Enabling autoconnect for network: $conn"
            nmcli connection modify "$conn" connection.autoconnect yes 2>/dev/null || true
            nmcli connection modify "$conn" connection.autoconnect-priority 10 2>/dev/null || true
        done
    fi
}

# Check if WiFi Connect is running
wifi_connect_running() {
    systemctl is-active --quiet wifi-connect
}

# Start WiFi Connect (captive portal)
start_wifi_connect() {
    # Make absolutely sure NetworkManager isn't trying to manage the interface
    log "Preparing to start captive portal..."

    # Don't start if we're already connected
    if has_wifi_connection; then
        log "WiFi connection detected, not starting captive portal"
        return 1
    fi

    log "No WiFi connection detected, starting captive portal..."

    # Ensure WiFi Connect doesn't conflict with NetworkManager
    # WiFi Connect will manage the interface when it starts
    systemctl start wifi-connect

    if systemctl is-active --quiet wifi-connect; then
        log "WiFi Connect captive portal started successfully on port 80"
        log "Connect to 'Ossuary-Setup' network to configure WiFi"
    else
        log "ERROR: Failed to start WiFi Connect"
        # If WiFi Connect fails, ensure NetworkManager can take back control
        nmcli device set wlan0 managed yes 2>/dev/null || true
    fi
}

# Stop WiFi Connect
stop_wifi_connect() {
    if wifi_connect_running; then
        log "WiFi connection restored, stopping captive portal..."
        systemctl stop wifi-connect
        log "Captive portal stopped"

        # Give NetworkManager full control back
        sleep 1
        nmcli device set wlan0 managed yes 2>/dev/null || true

        # Trigger a reconnection attempt with saved networks
        sleep 1
        nmcli device connect wlan0 2>/dev/null || true
    fi
}

# Wait for network on boot
wait_for_network_on_boot() {
    local waited=0

    # Initial wait for NetworkManager to fully initialize
    log "Waiting ${INITIAL_WAIT}s for NetworkManager to initialize..."
    sleep $INITIAL_WAIT

    # Check if there are saved networks
    if has_saved_networks; then
        log "Found saved networks, waiting for auto-connection..."

        # Ensure all saved networks have autoconnect enabled
        ensure_autoconnect

        # Try to explicitly connect to saved networks
        try_connect_saved_networks

        # Extended wait time for saved networks
        while [ $waited -lt $MAX_WAIT_FOR_NETWORK ]; do
            if has_wifi_connection; then
                log "WiFi connection established after ${waited}s"
                return 0
            fi

            # Periodically try to reconnect
            if [ $((waited % 60)) -eq 0 ] && [ $waited -gt 0 ]; then
                log "Retrying connection to saved networks..."
                try_connect_saved_networks
            fi

            sleep 5
            waited=$((waited + 5))

            if [ $((waited % 30)) -eq 0 ]; then
                log "Still waiting for saved network connection... (${waited}s/${MAX_WAIT_FOR_NETWORK}s)"
            fi
        done

        log "Could not connect to saved networks after ${MAX_WAIT_FOR_NETWORK}s"
    else
        log "No saved networks found, checking for existing connection..."

        # Quick check for any existing connection
        if has_wifi_connection; then
            log "WiFi connection already established"
            return 0
        fi

        # Short wait in case of temporary network
        local quick_wait=30
        while [ $waited -lt $quick_wait ]; do
            if has_wifi_connection; then
                log "WiFi connection found after ${waited}s"
                return 0
            fi

            sleep 5
            waited=$((waited + 5))
        done

        log "No saved networks and no connection after ${quick_wait}s"
    fi

    return 1
}

# Main monitoring loop
monitor_network() {
    log "Starting WiFi connection monitoring..."
    local last_network_check=0
    local network_check_interval=300  # Check saved networks every 5 minutes

    while true; do
        local current_time=$(date +%s)

        if has_wifi_connection; then
            # We have WiFi, make sure captive portal is off
            stop_wifi_connect

            # Periodically ensure autoconnect is enabled for saved networks
            if [ $((current_time - last_network_check)) -gt $network_check_interval ]; then
                ensure_autoconnect
                last_network_check=$current_time
            fi

            # Also check if we have internet
            if has_internet; then
                # All good, check again later
                sleep $CHECK_INTERVAL
            else
                log "WiFi connected but no internet, waiting..."
                sleep $((CHECK_INTERVAL / 2))  # Check more frequently
            fi
        else
            # No WiFi connection detected

            # First check if we have saved networks and try to connect
            if has_saved_networks; then
                log "No connection but saved networks exist, trying to reconnect..."
                ensure_autoconnect
                try_connect_saved_networks

                # Give it a moment to connect
                sleep 10

                # Check again
                if has_wifi_connection; then
                    log "Successfully reconnected to saved network"
                    continue
                fi
            fi

            # Still no connection, start captive portal if not already running
            if ! wifi_connect_running; then
                if has_saved_networks; then
                    log "Could not connect to saved networks, starting captive portal..."
                else
                    log "No saved networks found, starting captive portal..."
                fi
                start_wifi_connect
            fi

            # Check more frequently when in AP mode
            sleep $((CHECK_INTERVAL / 3))
        fi
    done
}

# Signal handlers
handle_term() {
    log "Received TERM signal, shutting down..."
    stop_wifi_connect
    exit 0
}

handle_hup() {
    log "Received HUP signal, reloading..."
    # Could reload config here if needed
}

trap handle_term TERM INT
trap handle_hup HUP

# Main execution
main() {
    log "===== WiFi Connect Manager Starting ====="
    log "PID: $$"

    # Ensure network persistence is configured
    if [ -x "/opt/ossuary/scripts/ensure-network-persistence.sh" ]; then
        log "Running network persistence check..."
        /opt/ossuary/scripts/ensure-network-persistence.sh
    fi

    # On boot, wait a bit for the network to come up
    wait_for_network_on_boot

    # Start the monitoring loop
    monitor_network
}

# Run main function
main "$@"