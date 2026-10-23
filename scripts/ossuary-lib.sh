#!/bin/bash
# Shared helpers for the Ossuary daemons. Source this file; it has no side effects.
#
# The kiosk runs as the desktop user that Raspberry Pi OS logs in automatically.
# That user is NOT always "pi": Raspberry Pi Imager lets people pick any name, and
# images built without the default user have none at all. Everything that needs
# the kiosk user, its home, or its display session goes through these functions.

OSSUARY_CONFIG_FILE="${OSSUARY_CONFIG_FILE:-/etc/ossuary/config.json}"

# Print the kiosk user's name.
# Order: explicit "kiosk_user" in config.json > the regular user that owns the
# graphical session on screen right now > LightDM autologin user > the uid 1000
# account > the first regular account.
ossuary_kiosk_user() {
    local user="" sock uid

    if [ -f "$OSSUARY_CONFIG_FILE" ]; then
        user=$(python3 -c '
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("kiosk_user") or "").strip())
except Exception:
    pass
' "$OSSUARY_CONFIG_FILE" 2>/dev/null)
    fi

    # Whoever is actually logged in on the display wins over configuration:
    # launching into anyone else's session fails ("Failed to connect to Wayland
    # display") and leaves the screen empty.
    if [ -z "$user" ]; then
        for sock in /run/user/*/wayland-[0-9]; do
            [ -S "$sock" ] || continue
            uid=$(stat -c %u "$sock" 2>/dev/null) || continue
            if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; then
                user=$(getent passwd "$uid" | cut -d: -f1)
                [ -n "$user" ] && break
            fi
        done
    fi

    if [ -z "$user" ]; then
        local f
        for f in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
            [ -f "$f" ] || continue
            user=$(sed -n 's/^[[:space:]]*autologin-user[[:space:]]*=[[:space:]]*//p' "$f" | tail -1)
            [ -n "$user" ] && break
        done
    fi

    if [ -z "$user" ] || ! id "$user" >/dev/null 2>&1; then
        user=$(getent passwd 1000 | cut -d: -f1)
    fi

    if [ -z "$user" ]; then
        user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
    fi

    echo "$user"
}

ossuary_user_home() {
    getent passwd "$1" | cut -d: -f6
}

# Name of the user's Wayland socket (wayland-0, wayland-1, ...), or empty.
ossuary_wayland_socket() {
    local uid sock
    uid=$(id -u "$1" 2>/dev/null) || return 0
    for sock in /run/user/"$uid"/wayland-[0-9]*; do
        case "$sock" in *.lock) continue ;; esac
        if [ -S "$sock" ]; then
            basename "$sock"
            return 0
        fi
    done
}

# "wayland", "x11" or "unknown" for the user's graphical session.
ossuary_display_type() {
    if [ -n "$(ossuary_wayland_socket "$1")" ]; then
        echo "wayland"
    elif [ -S /tmp/.X11-unix/X0 ]; then
        echo "x11"
    elif pgrep -x labwc >/dev/null || pgrep -x wayfire >/dev/null; then
        # Compositor is up but its socket isn't yet: treat as Wayland.
        echo "wayland"
    else
        echo "unknown"
    fi
}

# Print "export VAR='value';" statements that put a shell into the user's
# graphical session. Safe to eval or to pass to `su -c`.
ossuary_session_exports() {
    local user="$1" uid home sock
    uid=$(id -u "$user")
    home=$(ossuary_user_home "$user")
    printf "export HOME='%s'; export USER='%s'; export XDG_RUNTIME_DIR='/run/user/%s'; " "$home" "$user" "$uid"
    printf "export DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/%s/bus'; " "$uid"
    sock=$(ossuary_wayland_socket "$user")
    if [ -n "$sock" ]; then
        printf "export WAYLAND_DISPLAY='%s'; export XDG_SESSION_TYPE='wayland'; " "$sock"
    else
        printf "export DISPLAY=':0'; export XAUTHORITY='%s/.Xauthority'; export XDG_SESSION_TYPE='x11'; " "$home"
    fi
}

# Wait up to $2 seconds (default 60) for the user's graphical session.
ossuary_wait_for_display() {
    local user="$1" max="${2:-60}" waited=0
    while [ "$waited" -lt "$max" ]; do
        if [ -n "$(ossuary_wayland_socket "$user")" ] || [ -S /tmp/.X11-unix/X0 ]; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# True when the default route's gateway answers (or is at least resolved at
# layer 2). Works on LANs with no internet and on networks that drop ICMP to
# the outside world.
ossuary_has_lan() {
    local gw
    gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    [ -n "$gw" ] || return 1
    ping -c 1 -W 1 "$gw" >/dev/null 2>&1 && return 0
    ip neigh show "$gw" 2>/dev/null | grep -qE 'REACHABLE|STALE|DELAY|PROBE'
}
