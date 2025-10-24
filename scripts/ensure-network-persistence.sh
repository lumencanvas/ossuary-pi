#!/bin/bash

# Ensure WiFi networks are properly configured for persistence
# This script ensures NetworkManager saves and auto-connects to WiFi networks

LOG_FILE="/var/log/wifi-connect-manager.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [network-persistence] $1" | tee -a "$LOG_FILE"
}

# Enable autoconnect for all WiFi connections
enable_autoconnect_all() {
    if command -v nmcli >/dev/null; then
        log "Ensuring all WiFi networks have autoconnect enabled..."

        # Get all WiFi connections
        while IFS=: read -r type name; do
            if [ "$type" = "802-11-wireless" ]; then
                log "Configuring network: $name"

                # Enable autoconnect
                nmcli connection modify "$name" connection.autoconnect yes 2>/dev/null || \
                    log "Warning: Could not modify autoconnect for $name"

                # Set autoconnect priority
                nmcli connection modify "$name" connection.autoconnect-priority 10 2>/dev/null || \
                    log "Warning: Could not set priority for $name"

                # Ensure the connection is saved to disk
                nmcli connection reload 2>/dev/null || true
            fi
        done < <(nmcli -t -f TYPE,NAME connection show 2>/dev/null)

        log "Network persistence configuration complete"
    else
        log "NetworkManager (nmcli) not found"
    fi
}

# Check if NetworkManager is saving connections properly
check_nm_config() {
    local nm_conf="/etc/NetworkManager/NetworkManager.conf"

    if [ -f "$nm_conf" ]; then
        # Check if plugins include keyfile (needed for persistence)
        if ! grep -q "^plugins.*keyfile" "$nm_conf" 2>/dev/null; then
            log "Warning: NetworkManager may not be configured for persistent connections"

            # Try to add keyfile plugin if we have permission
            if [ -w "$nm_conf" ]; then
                log "Adding keyfile plugin to NetworkManager configuration..."

                # Backup the original
                cp "$nm_conf" "${nm_conf}.backup.$(date +%s)"

                # Add or modify plugins line
                if grep -q "^plugins=" "$nm_conf"; then
                    sed -i 's/^plugins=.*/plugins=keyfile/' "$nm_conf"
                else
                    echo -e "\n[main]\nplugins=keyfile" >> "$nm_conf"
                fi

                # Restart NetworkManager to apply changes
                systemctl restart NetworkManager 2>/dev/null || \
                    log "Warning: Could not restart NetworkManager"
            fi
        fi
    fi
}

# Ensure connection files are properly saved
ensure_connection_files() {
    local conn_dir="/etc/NetworkManager/system-connections"

    # Create directory if it doesn't exist
    if [ ! -d "$conn_dir" ]; then
        log "Creating NetworkManager system-connections directory..."
        mkdir -p "$conn_dir"
        chmod 755 "$conn_dir"
    fi

    # Check permissions
    if [ -d "$conn_dir" ]; then
        chmod 755 "$conn_dir"

        # Fix permissions on connection files
        for file in "$conn_dir"/*.nmconnection; do
            if [ -f "$file" ]; then
                chmod 600 "$file"
                chown root:root "$file"
            fi
        done
    fi
}

# Main execution
main() {
    log "Starting network persistence check..."

    # Check NetworkManager configuration
    check_nm_config

    # Ensure connection files directory exists and has proper permissions
    ensure_connection_files

    # Enable autoconnect for all WiFi networks
    enable_autoconnect_all

    # Force NetworkManager to reload connections
    if command -v nmcli >/dev/null; then
        nmcli connection reload
        log "NetworkManager connections reloaded"
    fi

    log "Network persistence check complete"
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi