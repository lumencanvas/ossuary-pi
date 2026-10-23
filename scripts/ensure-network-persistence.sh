#!/bin/bash

# Ensure saved WiFi networks survive reboots and reconnect on their own.
# Runs at the start of wifi-connect-manager and once during install.
#
# Hotspot (access-point mode) profiles are deliberately skipped: turning
# autoconnect on for one would make the Pi start an access point at boot.

log() {
    echo "[network-persistence] $1"
}

enable_autoconnect_all() {
    local type uuid mode name
    # UUIDs never contain ':' so the terse output splits safely, unlike names.
    while IFS=: read -r type uuid; do
        [ "$type" = "802-11-wireless" ] || continue
        mode=$(nmcli -g 802-11-wireless.mode connection show "$uuid" 2>/dev/null)
        [ "$mode" = "ap" ] && continue
        if [ "$(nmcli -g connection.autoconnect connection show "$uuid" 2>/dev/null)" != "yes" ]; then
            name=$(nmcli -g connection.id connection show "$uuid" 2>/dev/null)
            log "Enabling autoconnect for '$name'"
            nmcli connection modify "$uuid" connection.autoconnect yes 2>/dev/null || \
                log "Warning: could not enable autoconnect for '$name'"
        fi
    done < <(nmcli -t -f TYPE,UUID connection show 2>/dev/null)
}

check_nm_config() {
    local nm_conf="/etc/NetworkManager/NetworkManager.conf"
    [ -f "$nm_conf" ] || return 0
    if ! grep -q "^plugins=.*keyfile" "$nm_conf" 2>/dev/null; then
        log "NetworkManager is not using the keyfile plugin; enabling it"
        cp "$nm_conf" "${nm_conf}.backup.$(date +%s)"
        if grep -q "^plugins=" "$nm_conf"; then
            sed -i 's/^plugins=\(.*\)/plugins=\1,keyfile/' "$nm_conf"
        else
            printf '\n[main]\nplugins=keyfile\n' >> "$nm_conf"
        fi
        systemctl restart NetworkManager 2>/dev/null || log "Warning: could not restart NetworkManager"
    fi
}

ensure_connection_files() {
    local conn_dir="/etc/NetworkManager/system-connections" file
    mkdir -p "$conn_dir"
    chmod 700 "$conn_dir"
    for file in "$conn_dir"/*.nmconnection; do
        [ -f "$file" ] || continue
        chmod 600 "$file"
        chown root:root "$file"
    done
}

main() {
    command -v nmcli >/dev/null || { log "nmcli not found"; return 0; }
    check_nm_config
    ensure_connection_files
    enable_autoconnect_all
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
