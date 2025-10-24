#!/bin/bash

# Ossuary Process Manager
# Keeps user's command running continuously with automatic restart

CONFIG_FILE="/etc/ossuary/config.json"
LOG_FILE="/var/log/ossuary-process.log"
PID_FILE="/run/ossuary/process.pid"
RESTART_DELAY=5

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to get command from config
get_command() {
    if [ -f "$CONFIG_FILE" ]; then
        # Extract startup_command from JSON
        python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        config = json.load(f)
        print(config.get('startup_command', ''))
except:
    pass
"
    fi
}

# Function to detect display server type
detect_display_server() {
    # Check XDG_SESSION_TYPE first (most reliable on Pi OS 2025)
    if [ -n "$XDG_SESSION_TYPE" ]; then
        case "$XDG_SESSION_TYPE" in
            "wayland"|"x11") echo "$XDG_SESSION_TYPE"; return ;;
        esac
    fi

    # Check for Wayland (Pi OS 2025 uses Wayfire by default)
    if [ -n "$WAYLAND_DISPLAY" ] || [ -n "$XDG_RUNTIME_DIR" ]; then
        echo "wayland"
        return
    fi

    # Check for X11
    if [ -n "$DISPLAY" ]; then
        echo "x11"
        return
    fi

    # Try to detect from running processes (Pi OS 2025 specific)
    if pgrep -x "Xorg" > /dev/null || pgrep -x "X" > /dev/null; then
        echo "x11"
        return
    fi

    # Pi OS 2025 Wayland compositors
    if pgrep -x "wayfire" > /dev/null || pgrep -x "weston" > /dev/null || pgrep -x "sway" > /dev/null || pgrep -x "labwc" > /dev/null; then
        echo "wayland"
        return
    fi

    # Check systemctl for display manager (modern approach)
    if systemctl is-active --quiet gdm3 || systemctl is-active --quiet lightdm; then
        # If display manager is running, likely has a display server
        if [ -S "/run/user/$(id -u)/wayland-0" ] 2>/dev/null; then
            echo "wayland"
        else
            echo "x11"
        fi
        return
    fi

    echo "unknown"
}

# Function to wait for display (for GUI apps)
wait_for_display() {
    local max_wait=60  # Increased wait time for boot scenarios
    local waited=0
    local display_type=$(detect_display_server)

    log "Detected display server: $display_type"

    while [ $waited -lt $max_wait ]; do
        # For Wayland (Pi OS 2025 default)
        if [ "$display_type" = "wayland" ]; then
            # Check for Wayland socket
            if [ -n "$XDG_RUNTIME_DIR" ] && [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
                log "Wayland display socket is ready"
                return 0
            fi
            # Check if any Wayland compositor is running
            if pgrep -x "wayfire" > /dev/null || pgrep -x "weston" > /dev/null || pgrep -x "sway" > /dev/null || pgrep -x "labwc" > /dev/null; then
                log "Wayland compositor is running"
                return 0
            fi
            # Check for WAYLAND_DISPLAY environment variable
            if [ -n "$WAYLAND_DISPLAY" ]; then
                log "WAYLAND_DISPLAY is set"
                return 0
            fi
        # For X11
        elif [ "$display_type" = "x11" ] || [ "$display_type" = "unknown" ]; then
            # Modern X11 check - test if we can connect to display
            if [ -n "$DISPLAY" ]; then
                # Use a simple X11 test that should work on most systems
                if timeout 2 xwininfo -root &>/dev/null; then
                    log "X11 display is ready"
                    return 0
                fi
                # Fallback X11 checks
                if command -v xset >/dev/null && timeout 2 xset q &>/dev/null; then
                    log "X11 display ready (xset)"
                    return 0
                fi
                if command -v xdpyinfo >/dev/null && timeout 2 xdpyinfo &>/dev/null; then
                    log "X11 display ready (xdpyinfo)"
                    return 0
                fi
            fi
        fi

        log "Waiting for display server ($display_type)... [${waited}s/${max_wait}s]"
        sleep 2
        waited=$((waited + 2))

        # Re-detect in case it started late
        if [ $waited -eq 20 ] || [ $waited -eq 40 ]; then
            display_type=$(detect_display_server)
            log "Re-detected display server: $display_type"
        fi
    done

    log "Display not ready after ${max_wait} seconds, continuing anyway"
    return 1
}

# Function to setup environment for GUI apps
setup_gui_environment() {
    local user_home=""
    local display_type=$(detect_display_server)

    # Get the home directory for the user
    if id "pi" &>/dev/null; then
        user_home=$(getent passwd pi | cut -d: -f6)
        local run_user="pi"
    else
        # Find first non-root user
        local default_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | head -1)
        if [ -n "$default_user" ]; then
            user_home=$(getent passwd "$default_user" | cut -d: -f6)
            local run_user="$default_user"
        else
            user_home="/home/pi"
            local run_user="pi"
        fi
    fi

    # Set common environment
    export HOME="$user_home"

    # Setup display-specific variables
    if [ "$display_type" = "wayland" ]; then
        # Wayland-specific setup
        export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u $run_user)}"
        export XDG_SESSION_TYPE="wayland"

        # Some apps need these even on Wayland
        export DISPLAY="${DISPLAY:-:0}"

        log "Wayland environment set: WAYLAND_DISPLAY=$WAYLAND_DISPLAY, XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
    else
        # X11-specific setup
        export DISPLAY="${DISPLAY:-:0}"
        export XAUTHORITY="${user_home}/.Xauthority"
        export XDG_SESSION_TYPE="x11"

        log "X11 environment set: DISPLAY=$DISPLAY, XAUTHORITY=$XAUTHORITY"
    fi

    log "Common environment set: HOME=$HOME, SESSION_TYPE=$XDG_SESSION_TYPE"
}

# Function to run and monitor the command
run_command() {
    local command="$1"
    local restart_count=0
    local is_gui_app=false

    log "Starting process manager for: $command"

    # Detect if this is a GUI application
    if echo "$command" | grep -qE "chromium|firefox|chrome|midori|DISPLAY="; then
        is_gui_app=true
        log "Detected GUI application"
    fi

    while true; do
        # Check if we should still be running
        if [ ! -f "$PID_FILE" ]; then
            log "PID file removed, stopping process manager"
            break
        fi

        # Get latest command from config (allows hot reload)
        local current_command=$(get_command)
        if [ "$current_command" != "$command" ]; then
            log "Command changed in config, restarting with new command"
            command="$current_command"
            restart_count=0

            # Re-detect GUI app
            if echo "$command" | grep -qE "chromium|firefox|chrome|midori|DISPLAY="; then
                is_gui_app=true
            else
                is_gui_app=false
            fi
        fi

        if [ -z "$command" ]; then
            log "No command configured, waiting..."
            sleep 10
            continue
        fi

        # Setup GUI environment if needed
        if [ "$is_gui_app" = true ]; then
            setup_gui_environment
            wait_for_display

            # Kill existing Chrome/Chromium instances if starting Chrome
            if echo "$command" | grep -qE "chrom(e|ium)"; then
                log "Killing existing Chrome/Chromium instances..."
                pkill -f "chrom(e|ium)" 2>/dev/null || true
                sleep 2
            fi
        fi

        # Run the command
        log "Starting process (attempt #$((restart_count + 1))): $command"

        # Parse out any environment variables from the command
        local clean_command="$command"
        local extra_env=""

        # Check if command starts with environment variable assignments
        # (like DISPLAY=:0 or FOO=bar command)
        if echo "$command" | grep -qE "^[A-Z_][A-Z0-9_]*="; then
            # Extract environment variables until we hit the actual command
            while echo "$clean_command" | grep -qE "^[A-Z_][A-Z0-9_]*="; do
                # Get the first env var
                local env_var=$(echo "$clean_command" | sed -E 's/^([A-Z_][A-Z0-9_]*=[^ ]+) .*/\1/')
                extra_env="$extra_env export $env_var;"
                # Remove it from the command
                clean_command=$(echo "$clean_command" | sed -E 's/^[A-Z_][A-Z0-9_]*=[^ ]+ //')
            done
            log "Extracted environment: $extra_env"
            log "Clean command: $clean_command"
        fi

        # Create a wrapper script to run the command and capture its PID
        local wrapper_script="/tmp/ossuary-wrapper-$$.sh"
        cat > "$wrapper_script" << WRAPPER_EOF
#!/bin/bash
# Write the actual command PID to a file
PID_FILE="${PID_FILE}.actual"

# Run the command and save its PID
if id "pi" &>/dev/null; then
    if [ "$is_gui_app" = true ]; then
        exec su pi -c "export DISPLAY='${DISPLAY:-:0}'; \
            export XAUTHORITY='${XAUTHORITY}'; \
            export HOME='${HOME}'; \
            export WAYLAND_DISPLAY='${WAYLAND_DISPLAY}'; \
            export XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR}'; \
            export XDG_SESSION_TYPE='${XDG_SESSION_TYPE}'; \
            $extra_env \
            exec $clean_command"
    else
        exec su pi -c "$extra_env exec $clean_command"
    fi
else
    # Find first non-root user
    default_user=\$(getent passwd | awk -F: '\$3 >= 1000 && \$3 < 65534 {print \$1}' | head -1)
    if [ -n "\$default_user" ]; then
        if [ "$is_gui_app" = true ]; then
            exec su "\$default_user" -c "export DISPLAY='${DISPLAY:-:0}'; \
                export XAUTHORITY='${XAUTHORITY}'; \
                export HOME='${HOME}'; \
                export WAYLAND_DISPLAY='${WAYLAND_DISPLAY}'; \
                export XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR}'; \
                export XDG_SESSION_TYPE='${XDG_SESSION_TYPE}'; \
                $extra_env \
                exec $clean_command"
        else
            exec su "\$default_user" -c "$extra_env exec $clean_command"
        fi
    else
        # Fallback to running as current user
        if [ "$is_gui_app" = true ]; then
            export DISPLAY='${DISPLAY:-:0}'
            export XAUTHORITY='${XAUTHORITY}'
            export HOME='${HOME}'
            export WAYLAND_DISPLAY='${WAYLAND_DISPLAY}'
            export XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR}'
            export XDG_SESSION_TYPE='${XDG_SESSION_TYPE}'
            eval "$extra_env"
        fi
        exec bash -c "$clean_command"
    fi
fi
WRAPPER_EOF

        chmod +x "$wrapper_script"

        # Start the wrapper script in a new session with output capture
        setsid bash "$wrapper_script" 2>&1 | while IFS= read -r line; do
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] OUTPUT: $line" >> "$LOG_FILE"
        done &

        CHILD_PID=$!
        echo $CHILD_PID > "${PID_FILE}.child"

        # Monitor the pipeline process
        wait $CHILD_PID
        EXIT_CODE=$?

        # Cleanup
        rm -f "$wrapper_script"

        rm -f "${PID_FILE}.child"

        # Log the exit
        if [ $EXIT_CODE -eq 0 ]; then
            log "Process exited normally (code 0)"
        else
            log "Process crashed with exit code $EXIT_CODE"
        fi

        restart_count=$((restart_count + 1))

        # If it crashed too many times too quickly, slow down
        if [ $restart_count -gt 10 ]; then
            log "Too many restarts, waiting 30 seconds before retry..."
            sleep 30
            restart_count=0
        else
            log "Restarting in $RESTART_DELAY seconds..."
            sleep $RESTART_DELAY
        fi
    done
}

# Function to stop the managed process and ALL its children
stop_process() {
    local killed_something=false

    # First try to kill using the actual PID if we have it
    if [ -f "${PID_FILE}.actual" ]; then
        local actual_pid=$(cat "${PID_FILE}.actual")
        if kill -0 "$actual_pid" 2>/dev/null; then
            log "Stopping actual process (PID $actual_pid)"
            kill -TERM "$actual_pid" 2>/dev/null
            killed_something=true
            sleep 2
            if kill -0 "$actual_pid" 2>/dev/null; then
                kill -KILL "$actual_pid" 2>/dev/null
            fi
        fi
        rm -f "${PID_FILE}.actual"
    fi

    # Then handle the wrapper/pipeline process
    if [ -f "${PID_FILE}.child" ]; then
        local child_pid=$(cat "${PID_FILE}.child")
        log "Stopping managed process and all children (PID $child_pid)"

        # Kill the entire process group to ensure ALL children die
        # This handles cases like chromium-browser which spawns multiple processes
        local pgid
        if pgid=$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d ' '); then
            if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
                log "Killing process group $pgid"
                # Send TERM signal to entire process group
                kill -TERM -"$pgid" 2>/dev/null
                killed_something=true
                sleep 3

                # Check if any processes in the group are still alive
                if ps --no-headers -g "$pgid" >/dev/null 2>&1; then
                    log "Some processes still alive, sending KILL signal"
                    kill -KILL -"$pgid" 2>/dev/null
                    sleep 1
                fi
            fi
        fi

        # Also kill the direct child PID as fallback
        if kill -0 "$child_pid" 2>/dev/null; then
            log "Killing direct child PID $child_pid"
            kill -TERM "$child_pid" 2>/dev/null
            killed_something=true
            sleep 2
            if kill -0 "$child_pid" 2>/dev/null; then
                kill -KILL "$child_pid" 2>/dev/null
            fi
        fi

        rm -f "${PID_FILE}.child"
    fi

    # Extra cleanup for GUI applications (common browser processes)
    if [ "$killed_something" = true ]; then
        if command -v pkill >/dev/null; then
            # Kill any lingering browser processes that might have been spawned
            pkill -f "chromium.*kiosk" 2>/dev/null || true
            pkill -f "firefox.*kiosk" 2>/dev/null || true
            pkill -f "chrome.*kiosk" 2>/dev/null || true
        fi
        log "Process cleanup complete"
    else
        log "No child process to stop"
    fi
}

# Signal handlers
handle_term() {
    log "Received TERM signal, shutting down..."
    stop_process
    rm -f "$PID_FILE"
    exit 0
}

handle_hup() {
    log "Received HUP signal, reloading configuration..."
    stop_process
    # Will restart with new config in main loop
}

# Trap signals
trap handle_term TERM INT
trap handle_hup HUP

# Main execution
main() {
    # Ensure runtime directory exists
    if [ ! -d "/run/ossuary" ]; then
        mkdir -p /run/ossuary
    fi

    # Check if already running
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 $OLD_PID 2>/dev/null; then
            log "Process manager already running (PID $OLD_PID)"
            exit 1
        fi
        rm -f "$PID_FILE"
    fi

    # Save our PID
    echo $$ > "$PID_FILE"

    log "==================================="
    log "Ossuary Process Manager started"
    log "PID: $$"
    log "==================================="

    # Wait for network if needed (extended timeout for boot scenarios)
    log "Waiting for network connectivity..."
    local network_found=false
    for i in {1..60}; do
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
            log "Network is up after $((i*2)) seconds"
            network_found=true
            break
        fi
        if [ $((i % 10)) -eq 0 ]; then
            log "Still waiting for network... ($((i*2))s/120s)"
        fi
        sleep 2
    done

    if [ "$network_found" = false ]; then
        log "WARNING: Network not available after 120 seconds, proceeding anyway"
    fi

    # Add startup delay for system stabilization (important for GUI apps)
    log "Waiting 10 seconds for system to stabilize..."
    sleep 10

    # Get and run the command
    COMMAND=$(get_command)

    if [ -n "$COMMAND" ]; then
        run_command "$COMMAND"
    else
        log "No startup command configured"
        # Still run the loop in case command is added later
        run_command ""
    fi

    # Cleanup
    rm -f "$PID_FILE"
    log "Process manager stopped"
}

# Run main function
main