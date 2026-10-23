#!/bin/bash

# Ossuary Process Manager
# Keeps the configured startup command running, as the desktop (kiosk) user,
# inside their graphical session. Shows the first-run welcome page while no
# command is configured.
#
# Signals: HUP = config changed (restart the command cleanly), TERM = stop.

CONFIG_FILE="/etc/ossuary/config.json"
LOG_FILE="/var/log/ossuary-process.log"
PID_FILE="/run/ossuary/process.pid"
RESTART_DELAY=5
WELCOME_URL="http://localhost:8081/welcome.html"
DEBUG_PORT=9222

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=ossuary-lib.sh
. "$SCRIPT_DIR/ossuary-lib.sh" 2>/dev/null || . /opt/ossuary/scripts/ossuary-lib.sh

# Kiosk flags added to every Chromium command that doesn't already set them.
# Deliberately NO --use-gl=egl: current Chromium only allows ANGLE on Linux and
# rejects it ("Requested GL implementation (gl=none,angle=none) not found"),
# which kills the GPU process and leaves WebGL unavailable.
CHROMIUM_KIOSK_FLAGS=(
    --password-store=basic
    --noerrdialogs
    --disable-infobars
    --no-first-run
    --disable-default-apps
    --disable-notifications
    --disable-session-crashed-bubble
    --autoplay-policy=no-user-gesture-required
    --enable-gpu-rasterization
    --check-for-update-interval=31536000
)

mkdir -p "$(dirname "$LOG_FILE")" /run/ossuary

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

get_command() {
    [ -f "$CONFIG_FILE" ] || return 0
    python3 -c '
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("startup_command") or "").strip())
except Exception:
    pass
' "$CONFIG_FILE" 2>/dev/null
}

# Memory watchdog settings as "enabled max_percent" (defaults: on, 90).
get_memory_watchdog() {
    python3 -c '
import json, sys
w = {}
try:
    w = (json.load(open(sys.argv[1])).get("behaviors") or {}).get("memory_watchdog") or {}
except Exception:
    pass
pct = w.get("max_percent", 90)
pct = pct if isinstance(pct, int) and 50 <= pct <= 98 else 90
print("1" if w.get("enabled", True) is not False else "0", pct)
' "$CONFIG_FILE" 2>/dev/null || echo "1 90"
}

# Percent of RAM + swap in use. Counting swap means a page that uses a lot of
# memory is left alone while swap still has room.
memory_used_percent() {
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
         END{ if (t+st > 0) printf "%d", 100 - (a+sf)*100/(t+st); else print 0 }' "${MEMINFO:-/proc/meminfo}"
}

# Restarts the kiosk command before the system runs out of memory (a leaking
# browser otherwise ends in the kernel OOM killer or a frozen screen). Acts
# only after two checks in a row over the limit (~1 min), then waits 5 min
# before it can act again.
MEMORY_CHECK_SECONDS=30
memory_watchdog() {
    trap - TERM INT HUP
    local manager=$1 over=0 last_restart=-300 enabled pct used
    while kill -0 "$manager" 2>/dev/null; do
        sleep "$MEMORY_CHECK_SECONDS"
        read -r enabled pct <<< "$(get_memory_watchdog)"
        [ "$enabled" = 1 ] && [ -f "${PID_FILE}.child" ] || { over=0; continue; }
        used=$(memory_used_percent)
        if [ "$used" -ge "$pct" ]; then
            over=$((over + 1))
        else
            over=0
        fi
        if [ "$over" -ge 2 ] && [ $((SECONDS - last_restart)) -ge 300 ]; then
            log "Memory at ${used}% (limit ${pct}%); restarting the kiosk command to free it"
            last_restart=$SECONDS
            over=0
            kill -HUP "$manager"
        fi
    done
}

is_chromium_command() {
    echo "$1" | grep -qE '(^|[[:space:]/])(chromium(-browser)?|google-chrome)([[:space:]]|$)'
}

# Clear Chromium's crash state so a power cut doesn't leave a "Restore pages?"
# bubble over the kiosk.
prepare_chromium() {
    local profile_dir="$1" prefs
    for prefs in "$profile_dir/Default/Preferences" "$profile_dir/Local State"; do
        [ -f "$prefs" ] || continue
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"Crashed"/"exit_type":"Normal"/' "$prefs" 2>/dev/null || true
    done
}

# Insert kiosk flags right after the chromium binary, skipping any the command
# already sets. Older Ossuary versions baked "/home/pi/..." and uid-1000 paths
# into commands; those are rewritten for the real kiosk user.
enhance_chromium_command() {
    local command="$1" user="$2" home="$3" display_type="$4"
    local flags=() flag name

    if [ "$home" != "/home/pi" ] && [ ! -d /home/pi ]; then
        command="${command//\/home\/pi\//$home/}"
    fi

    for flag in "${CHROMIUM_KIOSK_FLAGS[@]}"; do
        name="${flag%%=*}"
        echo "$command" | grep -q -- "$name" || flags+=("$flag")
    done
    # An isolated profile is required: Chromium refuses --remote-debugging-port
    # on the default profile, and the refresh feature needs that port.
    echo "$command" | grep -q -- "--user-data-dir" || flags+=("--user-data-dir=$home/.config/chromium-kiosk")
    echo "$command" | grep -q -- "--remote-debugging-port" || flags+=("--remote-debugging-port=$DEBUG_PORT")
    if [ "$display_type" = "wayland" ]; then
        echo "$command" | grep -q -- "--ozone-platform" || flags+=("--ozone-platform=wayland")
    fi

    if [ ${#flags[@]} -gt 0 ]; then
        command=$(printf '%s\n' "$command" | sed -E "0,/(^|[[:space:]\/])(chromium(-browser)?|google-chrome)([[:space:]]|$)/s##\1\2 ${flags[*]//\//\\/}\4#")
    fi
    echo "$command"
}

profile_dir_of() {
    local command="$1" home="$2"
    local dir
    dir=$(echo "$command" | grep -oE -- '--user-data-dir=[^[:space:]"'"'"']+' | head -1 | cut -d= -f2-)
    echo "${dir:-$home/.config/chromium-kiosk}"
}

# Variables older UI versions put in front of the command. The process manager
# knows the real session, so these are dropped in favour of detected values.
SESSION_VARS_RE='^(DISPLAY|XAUTHORITY|WAYLAND_DISPLAY|XDG_RUNTIME_DIR)='

CHILD_PID=""
RELOAD_REQUESTED=0

stop_process() {
    if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
        log "Stopping process group $CHILD_PID"
        kill -TERM -- "-$CHILD_PID" 2>/dev/null || kill -TERM "$CHILD_PID" 2>/dev/null
        local i
        for i in 1 2 3 4 5; do
            kill -0 "$CHILD_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL -- "-$CHILD_PID" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}.child"
}

handle_term() {
    log "Received TERM, shutting down"
    stop_process
    rm -f "$PID_FILE"
    exit 0
}

handle_hup() {
    log "Received HUP (configuration changed)"
    RELOAD_REQUESTED=1
    stop_process
}

trap handle_term TERM INT
trap handle_hup HUP

# Start a command as the kiosk user in its own process group; sets CHILD_PID.
launch_as_kiosk() {
    local user="$1" exports="$2" extra_env="$3" command="$4"
    local cmd_file
    cmd_file=$(mktemp /run/ossuary/cmd.XXXXXX)
    # The command goes through a file so nothing here re-interprets it.
    printf '%s' "$command" > "$cmd_file"
    chmod 644 "$cmd_file"
    setsid su "$user" -s /bin/bash -c "$exports $extra_env cd \"\$HOME\"; exec bash $cmd_file" >> "$LOG_FILE" 2>&1 &
    CHILD_PID=$!
    echo "$CHILD_PID" > "${PID_FILE}.child"
}

# Show the welcome page until a startup command is configured.
show_welcome_page() {
    local user="$1" home exports display_type
    home=$(ossuary_user_home "$user")
    log "No startup command configured: showing the welcome page as $user"
    ossuary_wait_for_display "$user" 90 || log "Display session not detected yet; launching anyway"
    display_type=$(ossuary_display_type "$user")
    exports=$(ossuary_session_exports "$user")
    prepare_chromium "$home/.config/chromium-kiosk"

    local cmd
    cmd=$(enhance_chromium_command "chromium --kiosk $WELCOME_URL" "$user" "$home" "$display_type")

    while [ -z "$(get_command)" ]; do
        if [ -z "$CHILD_PID" ] || ! kill -0 "$CHILD_PID" 2>/dev/null; then
            # The config server may still be starting: wait for it so the
            # browser doesn't open on an error page.
            local i
            for i in $(seq 1 30); do
                curl -s -o /dev/null --max-time 1 "$WELCOME_URL" && break
                sleep 1
            done
            launch_as_kiosk "$user" "$exports" "" "$cmd"
            log "Welcome page started (PID $CHILD_PID)"
        fi
        sleep 3
    done
    log "Startup command configured; closing the welcome page"
    stop_process
}

# Wait briefly for a LAN when the command loads a web page, so the first load
# doesn't hit Chromium's offline page. Never long: offline and LAN-only kiosks
# must not sit on a black screen, and the connection monitor reloads the page
# once the network comes back.
wait_for_network_if_needed() {
    local command="$1" i
    echo "$command" | grep -qE 'https?://' || return 0
    echo "$command" | grep -qE 'https?://(localhost|127\.0\.0\.1)' && return 0
    for i in $(seq 1 10); do
        ossuary_has_lan && return 0
        sleep 2
    done
    log "No network yet; starting anyway (the page reloads when the connection returns)"
}

run_command() {
    local user="$1" raw_command="$2"
    local home exports display_type command extra_env clean_command var
    local crash_count=0 window_start=$SECONDS exit_code

    home=$(ossuary_user_home "$user")
    wait_for_network_if_needed "$raw_command"

    while true; do
        RELOAD_REQUESTED=0
        if is_chromium_command "$raw_command"; then
            ossuary_wait_for_display "$user" 90 || log "Display session not detected; starting anyway"
        fi
        # Checked after the (possibly long) display wait, so a change saved
        # meanwhile is not launched with the old command.
        if [ "$(get_command)" != "$raw_command" ]; then
            log "Startup command changed"
            return 0
        fi
        display_type=$(ossuary_display_type "$user")
        exports=$(ossuary_session_exports "$user")

        # Split leading VAR=value assignments off the command.
        clean_command="$raw_command"
        extra_env=""
        while [[ "$clean_command" =~ ^([A-Z_][A-Z0-9_]*=[^[:space:]]*)[[:space:]]+(.*)$ ]]; do
            var="${BASH_REMATCH[1]}"
            clean_command="${BASH_REMATCH[2]}"
            if [[ "$var" =~ $SESSION_VARS_RE ]]; then
                log "Ignoring $var from the command (session detected automatically)"
            else
                extra_env="$extra_env export $(printf '%q' "$var");"
            fi
        done

        command="$clean_command"
        if is_chromium_command "$command"; then
            command=$(enhance_chromium_command "$command" "$user" "$home" "$display_type")
            prepare_chromium "$(profile_dir_of "$command" "$home")"
            pkill -x chromium 2>/dev/null; pkill -x chrome 2>/dev/null
            sleep 1
        fi

        if [ "$RELOAD_REQUESTED" = 1 ]; then
            continue  # configuration changed while preparing: re-read it
        fi
        log "Starting as $user ($display_type): $command"
        launch_as_kiosk "$user" "$exports" "$extra_env" "$command"
        wait "$CHILD_PID"
        exit_code=$?
        # `wait` returns early when a trapped signal arrives; wait for real exit.
        while kill -0 "$CHILD_PID" 2>/dev/null; do
            wait "$CHILD_PID"; exit_code=$?
        done
        rm -f "${PID_FILE}.child" /run/ossuary/cmd.*
        CHILD_PID=""

        if [ "$RELOAD_REQUESTED" = 1 ]; then
            log "Restarting with the current configuration"
            RELOAD_REQUESTED=0
            continue
        fi

        if [ "$exit_code" -eq 0 ]; then
            log "Process exited normally; restarting in ${RESTART_DELAY}s"
            sleep "$RESTART_DELAY"
            continue
        fi

        # Crash: back off if it keeps happening within five minutes.
        if [ $((SECONDS - window_start)) -gt 300 ]; then
            window_start=$SECONDS
            crash_count=0
        fi
        crash_count=$((crash_count + 1))
        if [ "$crash_count" -gt 5 ]; then
            log "Process crashed (exit $exit_code), $crash_count times in 5 minutes; waiting 60s"
            sleep 60
        else
            log "Process crashed (exit $exit_code); restarting in ${RESTART_DELAY}s"
            sleep "$RESTART_DELAY"
        fi
    done
}

main() {
    if [ -f "$PID_FILE" ]; then
        local old
        old=$(cat "$PID_FILE")
        if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
            log "Process manager already running (PID $old)"
            exit 1
        fi
    fi
    echo $$ > "$PID_FILE"
    rm -f /run/ossuary/cmd.*

    local user
    user=$(ossuary_kiosk_user)
    if [ -z "$user" ]; then
        log "ERROR: no desktop user found to run the kiosk as"
        sleep 30
        exit 1
    fi
    log "Ossuary process manager started (PID $$, kiosk user $user)"
    memory_watchdog $$ &

    while true; do
        local command
        command=$(get_command)
        if [ -z "$command" ]; then
            show_welcome_page "$user"
        else
            run_command "$user" "$command"
        fi
    done
}

main
