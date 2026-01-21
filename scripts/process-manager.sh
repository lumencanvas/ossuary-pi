#!/bin/bash

# Ossuary Process Manager
# Keeps user's command running continuously with automatic restart

CONFIG_FILE="/etc/ossuary/config.json"
LOG_FILE="/var/log/ossuary-process.log"
PID_FILE="/run/ossuary/process.pid"
RESTART_DELAY=5

# Essential Chromium flags for kiosk mode (prevents prompts, dialogs, first-run wizards)
CHROMIUM_KIOSK_FLAGS="--password-store=basic --disable-session-crashed-bubble --disable-infobars --noerrdialogs --no-first-run --disable-default-apps --disable-translate --disable-features=TranslateUI --disable-notifications --autoplay-policy=no-user-gesture-required --check-for-update-interval=31536000"

# GPU stability flags (--use-gl=egl fixes issues on Pi Zero 2 W and some Pi 4 configs)
CHROMIUM_GPU_FLAGS="--use-gl=egl --enable-gpu-rasterization --ignore-gpu-blocklist"

# Wayland-specific flags (Pi OS 2024+ uses Wayland by default)
CHROMIUM_WAYLAND_FLAGS="--ozone-platform=wayland --start-maximized"

# WebGPU/Performance flags for LumenCanvas and graphics-heavy apps (optional, can cause instability)
CHROMIUM_WEBGPU_FLAGS="--enable-features=Vulkan,UseSkiaRenderer,WebGPU --enable-unsafe-webgpu"

# User data directory for kiosk mode (isolated from normal browsing)
CHROMIUM_DATA_DIR="--user-data-dir=/home/pi/.config/chromium-kiosk"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log messages (outputs to stderr so it doesn't interfere with command substitution)
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

# Function to get command from config
get_command() {
    if [ -f "$CONFIG_FILE" ]; then
        # Extract startup_command from JSON using python with properly escaped path
        local config_path="$CONFIG_FILE"
        local cmd=$(python3 -c "
import json
import sys
try:
    with open(sys.argv[1], 'r') as f:
        config = json.load(f)
        cmd = config.get('startup_command', '') or ''
        print(cmd.strip())
except:
    pass
" "$config_path" 2>/dev/null)
        # Return trimmed command (handles whitespace-only values)
        echo "$cmd" | xargs 2>/dev/null || echo ""
    fi
}

# Function to prepare chromium (clear crash state, add essential flags)
prepare_chromium() {
    local user_home="$1"

    log "Preparing Chromium for kiosk mode..."

    # Clear crash state to prevent "Restore pages?" dialog
    local prefs_file="$user_home/.config/chromium/Default/Preferences"
    if [ -f "$prefs_file" ]; then
        log "Clearing Chromium crash state..."
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$prefs_file" 2>/dev/null || true
        sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$prefs_file" 2>/dev/null || true
    fi

    # Also check for chromium-browser preferences (some systems use this)
    local prefs_file_alt="$user_home/.config/chromium-browser/Default/Preferences"
    if [ -f "$prefs_file_alt" ]; then
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$prefs_file_alt" 2>/dev/null || true
        sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$prefs_file_alt" 2>/dev/null || true
    fi
}

# Function to enhance chromium command with essential flags
enhance_chromium_command() {
    local command="$1"
    local enhanced="$command"
    local display_type=$(detect_display_server)

    # Only enhance if this is a chromium command
    if ! echo "$command" | grep -qE "chrom(e|ium)"; then
        echo "$command"
        return
    fi

    log "Enhancing Chromium command for $display_type..."

    # Add password-store=basic if not present (prevents keyring prompts)
    if ! echo "$command" | grep -q "password-store"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --password-store=basic/')
    fi

    # Add disable-session-crashed-bubble if not present
    if ! echo "$command" | grep -q "disable-session-crashed-bubble"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --disable-session-crashed-bubble/')
    fi

    # Add noerrdialogs if not present
    if ! echo "$command" | grep -q "noerrdialogs"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --noerrdialogs/')
    fi

    # Add disable-infobars if not present
    if ! echo "$command" | grep -q "disable-infobars"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --disable-infobars/')
    fi

    # Add autoplay-policy if not present (needed for video content)
    if ! echo "$command" | grep -q "autoplay-policy"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --autoplay-policy=no-user-gesture-required/')
    fi

    # Add GPU stability flags (--use-gl=egl fixes issues on many Pi configs)
    if ! echo "$command" | grep -q "use-gl"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --use-gl=egl/')
    fi

    # Add GPU rasterization for better performance
    if ! echo "$command" | grep -q "enable-gpu-rasterization"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --enable-gpu-rasterization/')
    fi

    # Add no-first-run to skip setup wizard
    if ! echo "$command" | grep -q "no-first-run"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --no-first-run/')
    fi

    # Add disable-default-apps
    if ! echo "$command" | grep -q "disable-default-apps"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --disable-default-apps/')
    fi

    # Add disable-notifications
    if ! echo "$command" | grep -q "disable-notifications"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --disable-notifications/')
    fi

    # Add isolated user data directory for kiosk mode
    if ! echo "$command" | grep -q "user-data-dir"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --user-data-dir=\/home\/pi\/.config\/chromium-kiosk/')
    fi

    # Add remote debugging port for Chrome DevTools Protocol (used by connection-monitor for refresh)
    if ! echo "$command" | grep -q "remote-debugging-port"; then
        enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --remote-debugging-port=9222/')
    fi

    # Add Wayland-specific flags if running on Wayland (Pi OS 2024+ default)
    if [ "$display_type" = "wayland" ]; then
        if ! echo "$command" | grep -q "ozone-platform"; then
            enhanced=$(echo "$enhanced" | sed 's/chromium\(-browser\)\?/& --ozone-platform=wayland/')
            log "Added Wayland ozone platform flag"
        fi
    fi

    echo "$enhanced"
}

# Function to detect display server type
detect_display_server() {
    # Check XDG_SESSION_TYPE first (most reliable on Pi OS 2025+)
    if [ -n "$XDG_SESSION_TYPE" ]; then
        case "$XDG_SESSION_TYPE" in
            "wayland"|"x11") echo "$XDG_SESSION_TYPE"; return ;;
        esac
    fi

    # Check for Wayland socket file (most reliable runtime check)
    local user_id
    if id "pi" &>/dev/null; then
        user_id=$(id -u pi)
    else
        user_id=$(id -u)
    fi

    if [ -S "/run/user/${user_id}/wayland-0" ]; then
        echo "wayland"
        return
    fi

    # Check WAYLAND_DISPLAY environment variable
    if [ -n "$WAYLAND_DISPLAY" ]; then
        echo "wayland"
        return
    fi

    # Check for X11
    if [ -n "$DISPLAY" ]; then
        echo "x11"
        return
    fi

    # Pi OS Wayland compositors (labwc is default in 2024+, wayfire was 2023-2024)
    if pgrep -x "labwc" > /dev/null || pgrep -x "wayfire" > /dev/null || pgrep -x "weston" > /dev/null || pgrep -x "sway" > /dev/null; then
        echo "wayland"
        return
    fi

    # Try to detect from running processes for X11
    if pgrep -x "Xorg" > /dev/null || pgrep -x "X" > /dev/null; then
        echo "x11"
        return
    fi

    # Check systemctl for display manager (modern approach)
    if systemctl is-active --quiet gdm3 || systemctl is-active --quiet lightdm; then
        # If display manager is running, likely has a display server
        if [ -S "/run/user/${user_id}/wayland-0" ]; then
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
            # Check if any Wayland compositor is running (labwc is Pi OS 2024+ default)
            if pgrep -x "labwc" > /dev/null || pgrep -x "wayfire" > /dev/null || pgrep -x "weston" > /dev/null || pgrep -x "sway" > /dev/null; then
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
                pkill -f "chromium" 2>/dev/null || true
                pkill -f "chrome" 2>/dev/null || true
                sleep 2

                # Prepare chromium (clear crash state)
                prepare_chromium "$HOME"

                # Enhance command with essential kiosk flags
                command=$(enhance_chromium_command "$command")
                log "Final command: $command"
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

        # Create wrapper script and command file to avoid shell injection
        # The command is written to a separate file and read safely
        local wrapper_script="/tmp/ossuary-wrapper-$$.sh"
        local command_file="/tmp/ossuary-cmd-$$.txt"
        local env_file="/tmp/ossuary-env-$$.txt"

        # Write command and env vars to files (safe from injection)
        printf '%s' "$clean_command" > "$command_file"
        printf '%s' "$extra_env" > "$env_file"

        # Write wrapper script with heredoc that doesn't expand variables
        cat > "$wrapper_script" << 'WRAPPER_EOF'
#!/bin/bash
# Wrapper script - reads command from file to avoid injection

# Read configuration from environment (set by caller)
OSSUARY_CMD_FILE="$1"
OSSUARY_ENV_FILE="$2"
OSSUARY_IS_GUI="$3"
OSSUARY_DISPLAY="$4"
OSSUARY_XAUTH="$5"
OSSUARY_HOME="$6"
OSSUARY_WAYLAND="$7"
OSSUARY_XDG_RUNTIME="$8"
OSSUARY_SESSION_TYPE="$9"

# Read the actual command from file
if [ ! -f "$OSSUARY_CMD_FILE" ]; then
    echo "Error: Command file not found: $OSSUARY_CMD_FILE"
    exit 1
fi
OSSUARY_COMMAND=$(cat "$OSSUARY_CMD_FILE")

# Read env vars from file (may be empty)
OSSUARY_EXTRA_ENV=""
if [ -f "$OSSUARY_ENV_FILE" ]; then
    OSSUARY_EXTRA_ENV=$(cat "$OSSUARY_ENV_FILE")
fi

# Determine which user to run as
run_user=""
if id "pi" &>/dev/null; then
    run_user="pi"
else
    run_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | head -1)
fi

# Build the command to run
if [ "$OSSUARY_IS_GUI" = "true" ]; then
    gui_exports="export DISPLAY='$OSSUARY_DISPLAY'; export XAUTHORITY='$OSSUARY_XAUTH'; export HOME='$OSSUARY_HOME'; export WAYLAND_DISPLAY='$OSSUARY_WAYLAND'; export XDG_RUNTIME_DIR='$OSSUARY_XDG_RUNTIME'; export XDG_SESSION_TYPE='$OSSUARY_SESSION_TYPE';"
fi

if [ -n "$run_user" ]; then
    if [ "$OSSUARY_IS_GUI" = "true" ]; then
        exec su "$run_user" -s /bin/bash -c "$gui_exports $OSSUARY_EXTRA_ENV exec $OSSUARY_COMMAND"
    else
        exec su "$run_user" -s /bin/bash -c "$OSSUARY_EXTRA_ENV exec $OSSUARY_COMMAND"
    fi
else
    # Fallback to current user
    if [ "$OSSUARY_IS_GUI" = "true" ]; then
        export DISPLAY="$OSSUARY_DISPLAY"
        export XAUTHORITY="$OSSUARY_XAUTH"
        export HOME="$OSSUARY_HOME"
        export WAYLAND_DISPLAY="$OSSUARY_WAYLAND"
        export XDG_RUNTIME_DIR="$OSSUARY_XDG_RUNTIME"
        export XDG_SESSION_TYPE="$OSSUARY_SESSION_TYPE"
        eval "$OSSUARY_EXTRA_ENV"
    fi
    exec bash -c "$OSSUARY_COMMAND"
fi
WRAPPER_EOF

        chmod +x "$wrapper_script"

        # Start the wrapper script in a new session with arguments
        setsid bash "$wrapper_script" \
            "$command_file" \
            "$env_file" \
            "$is_gui_app" \
            "${DISPLAY:-:0}" \
            "${XAUTHORITY:-}" \
            "${HOME:-}" \
            "${WAYLAND_DISPLAY:-}" \
            "${XDG_RUNTIME_DIR:-}" \
            "${XDG_SESSION_TYPE:-}" \
            >> "$LOG_FILE" 2>&1 &
        CHILD_PID=$!
        echo $CHILD_PID > "${PID_FILE}.child"

        log "Started process with PID $CHILD_PID"

        # Wait for the process
        wait $CHILD_PID
        EXIT_CODE=$?

        # Cleanup wrapper and temp files
        rm -f "$wrapper_script" "$command_file" "$env_file"

        rm -f "${PID_FILE}.child"

        # Log the exit
        local current_time=$(date +%s)
        if [ $EXIT_CODE -eq 0 ]; then
            log "Process exited normally (code 0)"
            # Reset crash tracking on clean exit
            crash_count_in_window=0
            last_crash_time=0
        else
            log "Process crashed with exit code $EXIT_CODE"

            # Time-windowed crash detection (5 minute window)
            local CRASH_WINDOW=300

            # Initialize tracking vars if not set
            if [ -z "$last_crash_time" ]; then
                last_crash_time=0
                crash_count_in_window=0
            fi

            # Check if we're still within the crash window
            local time_since_last=$((current_time - last_crash_time))
            if [ $time_since_last -gt $CRASH_WINDOW ]; then
                # Outside window - reset counter
                crash_count_in_window=1
            else
                # Within window - increment counter
                crash_count_in_window=$((crash_count_in_window + 1))
            fi
            last_crash_time=$current_time

            log "Crashes in last 5 minutes: $crash_count_in_window"
        fi

        restart_count=$((restart_count + 1))

        # If it crashed too many times within the time window, slow down
        if [ "${crash_count_in_window:-0}" -gt 5 ]; then
            log "Too many crashes in short period ($crash_count_in_window in 5 minutes), waiting 30 seconds..."
            sleep 30
            # Reset window after long pause
            crash_count_in_window=0
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

# Path to welcome page
WELCOME_PAGE="/opt/ossuary/custom-ui/welcome.html"

# Function to check network connectivity
check_network() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
}

# Function to show the first-run welcome page
show_welcome_page() {
    log "Showing first-run welcome page..."

    # Setup GUI environment
    setup_gui_environment

    # Wait for display (shorter timeout for welcome page)
    local max_wait=30
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if wait_for_display; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # Prepare Chromium
    prepare_chromium "$HOME"

    # Kill any existing browsers
    pkill -f "chromium" 2>/dev/null || true
    pkill -f "chrome" 2>/dev/null || true
    sleep 1

    # Determine the user to run as
    local run_user="pi"
    if ! id "pi" &>/dev/null; then
        run_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | head -1)
    fi

    # Launch Chromium with welcome page in kiosk mode
    # Detect display type for proper flags
    local display_type=$(detect_display_server)
    local platform_flags=""
    local env_exports=""

    # Get the correct user ID for XDG_RUNTIME_DIR
    local run_user_id=$(id -u "$run_user" 2>/dev/null || echo "1000")

    if [ "$display_type" = "wayland" ]; then
        platform_flags="--ozone-platform=wayland"
        env_exports="export WAYLAND_DISPLAY='wayland-0'; export XDG_RUNTIME_DIR='/run/user/${run_user_id}'; export XDG_SESSION_TYPE='wayland';"
        log "Using Wayland display mode"
    else
        env_exports="export DISPLAY='${DISPLAY:-:0}'; export XAUTHORITY='${HOME}/.Xauthority';"
        log "Using X11 display mode"
    fi

    local chromium_cmd="chromium --kiosk --password-store=basic --disable-session-crashed-bubble --disable-infobars --noerrdialogs --no-first-run --disable-default-apps --disable-notifications --use-gl=egl --user-data-dir=/home/${run_user}/.config/chromium-kiosk --check-for-update-interval=31536000 --remote-debugging-port=9222 $platform_flags file://${WELCOME_PAGE}"

    log "Launching welcome page: $chromium_cmd"

    # Run as the appropriate user with correct environment
    su "$run_user" -c "${env_exports} export HOME='${HOME}'; $chromium_cmd" >> "$LOG_FILE" 2>&1 &

    WELCOME_PID=$!
    echo $WELCOME_PID > "${PID_FILE}.welcome"
    log "Welcome page browser started (PID $WELCOME_PID)"

    # Monitor for command being set
    log "Monitoring for startup command configuration..."
    while true; do
        sleep 3

        # Check if command has been set
        local current_command=$(get_command)
        if [ -n "$current_command" ]; then
            log "Startup command configured: $current_command"
            break
        fi

        # Check if welcome browser died
        if [ -f "${PID_FILE}.welcome" ]; then
            local wpid=$(cat "${PID_FILE}.welcome")
            if ! kill -0 "$wpid" 2>/dev/null; then
                log "Welcome browser died, restarting..."
                su "$run_user" -c "${env_exports} export HOME='${HOME}'; $chromium_cmd" >> "$LOG_FILE" 2>&1 &
                WELCOME_PID=$!
                echo $WELCOME_PID > "${PID_FILE}.welcome"
            fi
        fi
    done

    # Kill welcome page browser
    log "Closing welcome page..."
    if [ -f "${PID_FILE}.welcome" ]; then
        local wpid=$(cat "${PID_FILE}.welcome")
        kill -TERM "$wpid" 2>/dev/null || true
        sleep 1
        kill -KILL "$wpid" 2>/dev/null || true
        rm -f "${PID_FILE}.welcome"
    fi
    pkill -f "welcome.html" 2>/dev/null || true
    sleep 2
}

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

    # Check for first-run scenario (no command configured)
    COMMAND=$(get_command)

    if [ -z "$COMMAND" ]; then
        log "No startup command configured - checking for first-run scenario"

        # Wait briefly for system to stabilize
        log "Waiting 5 seconds for system to stabilize..."
        sleep 5

        # Check if welcome page exists
        if [ -f "$WELCOME_PAGE" ]; then
            # Show welcome page (will block until command is configured)
            show_welcome_page

            # Re-fetch command after welcome page closes
            COMMAND=$(get_command)
        else
            log "Welcome page not found at $WELCOME_PAGE"
        fi
    fi

    # If we still have no command, wait for network and command with periodic checks
    if [ -z "$COMMAND" ]; then
        log "Waiting for startup command to be configured..."
        while [ -z "$COMMAND" ]; do
            sleep 10
            COMMAND=$(get_command)
        done
    fi

    # Now we have a command - wait for network if needed
    log "Waiting for network connectivity..."
    local network_found=false
    for i in {1..60}; do
        if check_network; then
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
    log "Waiting 5 seconds for system to stabilize..."
    sleep 5

    # Run the configured command
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