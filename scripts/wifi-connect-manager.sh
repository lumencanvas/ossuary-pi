#!/bin/bash

# WiFi Connect Manager
# Decides when the "Ossuary-Setup" captive portal (balena wifi-connect) runs.
#
# Rules:
#   * The device is ONLINE when NetworkManager has an activated connection on an
#     ethernet device, or a wifi connection that is not an access point. The
#     hotspot itself never counts: while it is up, wlan0 is "connected" too.
#   * Ethernet counts. A wired kiosk must never advertise an open setup hotspot.
#   * While the portal runs, the radio belongs to wifi-connect and is left alone.
#     wifi-connect exits by itself when someone joins a network through it, or
#     after --activity-timeout if nobody opened the portal. Only then do we look
#     again, give saved networks another chance, and restart the portal if needed.
#   * Log on state changes only: this runs forever on an SD card.

CHECK_INTERVAL=10
BOOT_GRACE=90       # at boot, how long saved networks get to auto-connect
LOST_GRACE=120      # after losing a connection (router reboot), before opening the hotspot
RETRY_WINDOW=45     # after the portal times out, how long saved networks get

log() {
    # stdout goes to the journal (journalctl -u wifi-connect-manager)
    echo "$1"
}

wifi_iface() {
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}'
}

# Mode of a connection profile ("infrastructure", "ap", ...), by UUID.
conn_mode() {
    nmcli -g 802-11-wireless.mode connection show "$1" 2>/dev/null
}

is_online() {
    local dev type state uuid
    # CON-UUID never contains ':' so the terse output splits safely.
    while IFS=: read -r dev type state uuid; do
        case "$state" in
            connected|"connected (externally)") ;;
            *) continue ;;
        esac
        case "$type" in
            ethernet) return 0 ;;
            wifi) [ "$(conn_mode "$uuid")" != "ap" ] && return 0 ;;
        esac
    done < <(nmcli -t -f DEVICE,TYPE,STATE,CON-UUID device status 2>/dev/null)
    return 1
}

# Saved client (non-hotspot) wifi profiles exist?
has_saved_wifi() {
    local type uuid
    while IFS=: read -r type uuid; do
        [ "$type" = "802-11-wireless" ] || continue
        [ "$(conn_mode "$uuid")" != "ap" ] && return 0
    done < <(nmcli -t -f TYPE,UUID connection show 2>/dev/null)
    return 1
}

# Fresh Raspberry Pi OS images keep WiFi rfkill-blocked, and NetworkManager's
# radio switched off, until a WiFi country is set (pi-gen does this when the
# image is built without WPA_COUNTRY). The hotspot cannot start like that.
ensure_radio() {
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi 2>/dev/null || true
    fi
    nmcli radio wifi on 2>/dev/null || true
}

portal_running() {
    local s
    s=$(systemctl is-active wifi-connect 2>/dev/null)
    [ "$s" = "active" ] || [ "$s" = "activating" ]
}

start_portal() {
    ensure_radio
    log "Starting the Ossuary-Setup hotspot"
    systemctl start wifi-connect || log "ERROR: wifi-connect failed to start (journalctl -u wifi-connect)"
}

stop_portal() {
    if portal_running; then
        log "Stopping the Ossuary-Setup hotspot"
        systemctl stop wifi-connect
    fi
}

# Wait up to $1 seconds for any connection.
wait_online() {
    local max="$1" waited=0
    while [ "$waited" -lt "$max" ]; do
        is_online && return 0
        sleep 5
        waited=$((waited + 5))
    done
    is_online
}

# Ask NetworkManager to bring the best saved network up on the wifi device.
kick_saved_networks() {
    local iface
    iface=$(wifi_iface)
    [ -n "$iface" ] || return 1
    ensure_radio
    nmcli device connect "$iface" >/dev/null 2>&1 || true
}

STATE=""
set_state() {
    if [ "$1" != "$STATE" ]; then
        log "State: ${STATE:-boot} -> $1${2:+ ($2)}"
        STATE="$1"
    fi
}

handle_term() {
    log "Stopping"
    stop_portal
    exit 0
}
trap handle_term TERM INT

main() {
    log "WiFi Connect Manager starting (PID $$)"

    if [ -x /opt/ossuary/scripts/ensure-network-persistence.sh ]; then
        /opt/ossuary/scripts/ensure-network-persistence.sh
    fi

    # Let NetworkManager finish its own startup and autoconnect first.
    nm-online -s -q -t 60 2>/dev/null || true

    if ! is_online && has_saved_wifi; then
        log "Saved networks found; giving them ${BOOT_GRACE}s to connect"
        ensure_radio
        kick_saved_networks
        wait_online "$BOOT_GRACE"
    fi

    while true; do
        if is_online; then
            # Ethernet plugged in, or a network joined: the hotspot must go.
            stop_portal
            set_state online
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if [ -z "$(wifi_iface)" ]; then
            set_state no-wifi "no wifi device; plug in ethernet"
            sleep 30
            continue
        fi

        if portal_running; then
            set_state portal
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Offline and no portal.
        case "$STATE" in
            online)
                if has_saved_wifi; then
                    set_state reconnecting "connection lost"
                    kick_saved_networks
                    wait_online "$LOST_GRACE" && continue
                fi
                ;;
            portal)
                # wifi-connect exited: either nobody used it before the timeout,
                # or a connection attempt through it failed.
                if has_saved_wifi; then
                    set_state reconnecting "portal closed"
                    kick_saved_networks
                    wait_online "$RETRY_WINDOW" && continue
                fi
                ;;
        esac

        start_portal
        set_state portal
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
