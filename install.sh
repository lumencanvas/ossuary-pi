#!/bin/bash

# Ossuary Pi - Installation, Update, and Repair Script
# Handles fresh installs, updates existing installations, and repairs broken components
# Run with DEBUG=1 for verbose output: DEBUG=1 sudo ./install.sh

# Don't exit on error - handle errors explicitly
set +e

# Trap errors and log them
trap 'catch_error $? $LINENO' ERR

catch_error() {
    local exit_code=$1
    local line_no=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Command failed with exit code $exit_code at line $line_no" >> "$LOG_FILE"
    echo -e "${RED}[ERROR]${NC} Command failed at line $line_no (see $LOG_FILE for details)" >&2
}

# Configuration
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/ossuary"
CONFIG_DIR="/etc/ossuary"
CUSTOM_UI_DIR="$INSTALL_DIR/custom-ui"
LOG_FILE="/tmp/ossuary-install.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Helper functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    if [ "${DEBUG:-0}" = "1" ] || [ -t 1 ]; then
        echo -e "${GREEN}[INFO]${NC} $1"
    fi
}

debug() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $1" >> "$LOG_FILE"
    if [ "${DEBUG:-0}" = "1" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >> "$LOG_FILE"
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Show spinner for long operations
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Check if already installed
check_existing_installation() {
    local is_installed=false
    local needs_repair=false

    log "Checking for existing installation..."

    if [ -d "$INSTALL_DIR" ]; then
        is_installed=true
        log "Found installation directory at $INSTALL_DIR"
    else
        log "No installation directory found"
    fi

    # Check for systemd service
    if systemctl list-units --full -all 2>/dev/null | grep -q "wifi-connect.service"; then
        is_installed=true
        log "WiFi Connect service is registered"

        # Check if service is broken
        if ! systemctl is-active --quiet wifi-connect 2>/dev/null; then
            log "WiFi Connect service is not active, checking for issues..."
            local journal_output=$(journalctl -u wifi-connect -n 5 2>/dev/null || echo "Could not read journal")
            echo "$journal_output" >> "$LOG_FILE"

            if echo "$journal_output" | grep -q "No such file or directory"; then
                needs_repair=true
                warning "WiFi Connect binary is missing - will reinstall"
            elif echo "$journal_output" | grep -q "exit-code"; then
                needs_repair=true
                warning "WiFi Connect service has errors - will repair"
            fi
        else
            log "WiFi Connect service is active and running"
        fi
    else
        log "WiFi Connect service not found in systemd"
    fi

    if [ "$is_installed" = true ]; then
        if [ "$needs_repair" = true ]; then
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}       REPAIR MODE - FIXING BROKEN COMPONENTS     ${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            return 2  # Repair mode
        else
            echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BLUE}        UPDATE MODE - REFRESHING INSTALLATION     ${NC}"
            echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            return 1  # Update mode
        fi
    fi

    return 0  # Fresh install
}

# Backup configuration
backup_config() {
    if [ -f "$CONFIG_DIR/config.json" ]; then
        local backup_file="/tmp/ossuary-config-backup-$(date +%Y%m%d-%H%M%S).json"
        cp "$CONFIG_DIR/config.json" "$backup_file"
        log "Configuration backed up to $backup_file"
        echo "$backup_file"  # Return backup path
    fi
}

# Restore configuration
restore_config() {
    local backup_file="$1"
    if [ -f "$backup_file" ]; then
        mkdir -p "$CONFIG_DIR"
        cp "$backup_file" "$CONFIG_DIR/config.json"
        log "Configuration restored from $backup_file"
    fi
}

# Install or update WiFi Connect
install_wifi_connect() {
    local force_reinstall="${1:-false}"

    # Check if WiFi Connect exists and works
    if [ "$force_reinstall" != true ] && command -v wifi-connect &> /dev/null; then
        if wifi-connect --version &> /dev/null; then
            success "WiFi Connect binary is working"
            return 0
        fi
    fi

    log "Installing/updating WiFi Connect binary..."

    # Detect architecture - Pi 4/5 run 64-bit, older run 32-bit
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        WIFI_CONNECT_ARCH="aarch64-unknown-linux-gnu"
        log "Detected 64-bit ARM (Pi 4/5 with 64-bit OS)"
    elif [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armhf" ]; then
        WIFI_CONNECT_ARCH="armv7-unknown-linux-gnueabihf"
        log "Detected 32-bit ARM (Pi 3/Zero 2 W or 32-bit OS)"
    else
        error "Unsupported architecture: $ARCH"
    fi

    # Download directly from GitHub releases
    log "Downloading WiFi Connect from GitHub releases..."
    WIFI_CONNECT_VERSION="v4.11.84"  # Latest actual release (as of Oct 2024)
    DOWNLOAD_URL="https://github.com/balena-os/wifi-connect/releases/download/${WIFI_CONNECT_VERSION}/wifi-connect-${WIFI_CONNECT_ARCH}.tar.gz"

    # Show which Pi model we're installing for
    if [ -f /proc/device-tree/model ]; then
        MODEL=$(tr -d '\0' < /proc/device-tree/model)
        log "Installing for: $MODEL"
    fi

    cd /tmp
    rm -f wifi-connect.tar.gz wifi-connect  # Clean up any old files

    # Download WiFi Connect
    log "Downloading from: $DOWNLOAD_URL"
    if ! wget --progress=bar:force "$DOWNLOAD_URL" -O wifi-connect.tar.gz 2>&1 | tee -a "$LOG_FILE"; then
        log "Download failed - wget exit code: $?"
        error "Failed to download WiFi Connect (check network connection)"
    fi
    log "Download complete"

    log "Extracting WiFi Connect..."
    if ! tar -xzf wifi-connect.tar.gz >> "$LOG_FILE" 2>&1; then
        error "Failed to extract WiFi Connect"
    fi

    # Stop service if running
    if systemctl is-active --quiet wifi-connect; then
        systemctl stop wifi-connect
    fi

    mv wifi-connect /usr/local/bin/ >> "$LOG_FILE" 2>&1
    chmod +x /usr/local/bin/wifi-connect
    rm -f wifi-connect.tar.gz

    # Verify installation
    if ! command -v wifi-connect &> /dev/null; then
        error "WiFi Connect installation failed"
    fi

    if wifi-connect --version &> /dev/null; then
        success "WiFi Connect binary installed and verified"
    else
        warning "WiFi Connect installed but may have issues"
    fi
}

# Update custom UI and scripts
update_components() {
    log "Updating Ossuary components..."

    # Create directories
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CUSTOM_UI_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/scripts"

    # Copy custom UI
    if [ -d "$REPO_DIR/custom-ui" ]; then
        cp -r "$REPO_DIR/custom-ui"/* "$CUSTOM_UI_DIR/"
        success "Custom UI updated"
    fi

    # Copy scripts
    if [ -f "$REPO_DIR/scripts/process-manager.sh" ]; then
        cp "$REPO_DIR/scripts/process-manager.sh" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/process-manager.sh"
        success "Process manager script installed"
    else
        error "Process manager script not found!"
    fi

    if [ -f "$REPO_DIR/scripts/wifi-connect-manager.sh" ]; then
        cp "$REPO_DIR/scripts/wifi-connect-manager.sh" "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/wifi-connect-manager.sh"
        success "WiFi Connect manager script installed"
    else
        error "WiFi Connect manager script not found!"
    fi

    if [ -f "$REPO_DIR/scripts/ensure-network-persistence.sh" ]; then
        cp "$REPO_DIR/scripts/ensure-network-persistence.sh" "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/ensure-network-persistence.sh"
        success "Network persistence script installed"

        # Run it immediately to ensure existing networks are configured
        log "Configuring network persistence..."
        "$INSTALL_DIR/scripts/ensure-network-persistence.sh" >> "$LOG_FILE" 2>&1 || true
    fi

    # Use enhanced config server if available, fallback to basic version
    if [ -f "$REPO_DIR/scripts/config-server-enhanced.py" ]; then
        cp "$REPO_DIR/scripts/config-server-enhanced.py" "$INSTALL_DIR/scripts/config-server.py"
        chmod +x "$INSTALL_DIR/scripts/config-server.py"
        success "Enhanced config server installed"
    elif [ -f "$REPO_DIR/scripts/config-server.py" ]; then
        cp "$REPO_DIR/scripts/config-server.py" "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/config-server.py"
        success "Basic config server installed"
    fi

    success "Scripts updated"
}

# Update systemd services
update_services() {
    log "Updating systemd services..."

    # WiFi Connect service - ONLY runs when no WiFi connection
    cat > /etc/systemd/system/wifi-connect.service << EOF
[Unit]
Description=Balena WiFi Connect - Captive Portal (only when disconnected)
After=NetworkManager.service
Wants=NetworkManager.service
# Don't start automatically - let wifi-connect-manager decide

[Service]
Type=simple
ExecStart=/usr/local/bin/wifi-connect \\
    --portal-ssid "Ossuary-Setup" \\
    --ui-directory $CUSTOM_UI_DIR \\
    --activity-timeout 600 \\
    --portal-listening-port 80
Restart=no
Environment="DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"

[Install]
# Not enabled by default - managed by wifi-connect-manager
EOF

    # Process manager service (keeps command running)
    cat > /etc/systemd/system/ossuary-startup.service << EOF
[Unit]
Description=Ossuary Process Manager - Keeps User Command Running
After=network-online.target multi-user.target NetworkManager.service
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'until ping -c1 8.8.8.8 &>/dev/null || ping -c1 1.1.1.1 &>/dev/null; do sleep 5; done'
ExecStart=$INSTALL_DIR/process-manager.sh
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=180
RuntimeDirectory=ossuary
RuntimeDirectoryMode=0755

# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

    # WiFi Connect Manager - Intelligently manages captive portal
    cat > /etc/systemd/system/wifi-connect-manager.service << EOF
[Unit]
Description=WiFi Connect Manager - Smart Captive Portal Control
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=$INSTALL_DIR/scripts/wifi-connect-manager.sh
Restart=always
RestartSec=10
User=root

# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Web configuration service (ALWAYS on port 8080 to avoid conflicts)
    cat > /etc/systemd/system/ossuary-web.service << EOF
[Unit]
Description=Ossuary Web Configuration Interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/scripts/config-server.py --port 8080
Restart=always
RestartSec=10
User=root
WorkingDirectory=$INSTALL_DIR

# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    success "Services updated"
}

# Main installation function
perform_installation() {
    local mode="$1"  # 0=fresh, 1=update, 2=repair
    local backup_file=""

    # Backup existing config if updating/repairing
    if [ "$mode" -gt 0 ]; then
        backup_file=$(backup_config)
    fi

    # Step 1: Install dependencies (only for fresh install)
    if [ "$mode" -eq 0 ]; then
        log "Installing dependencies..."
        echo "  Updating package lists..."
        apt-get update >> "$LOG_FILE" 2>&1
        echo "  Installing required packages..."
        # Note: network-manager is pre-installed in Pi OS Bookworm/Trixie
        # But we include it to be safe for older versions
        apt-get install -y curl wget jq network-manager python3 python3-pip >> "$LOG_FILE" 2>&1

        # Install Python packages if needed (for config server)
        if ! python3 -c "import json" 2>/dev/null; then
            apt-get install -y python3-json >> "$LOG_FILE" 2>&1
        fi

        # NetworkManager is default in Pi OS Bookworm (2023) and Trixie (2025)
        # But we'll ensure it's enabled
        if ! systemctl is-active --quiet NetworkManager; then
            log "Enabling NetworkManager..."
            systemctl enable NetworkManager >> "$LOG_FILE" 2>&1
            systemctl start NetworkManager >> "$LOG_FILE" 2>&1

            # Wait for NetworkManager to fully start
            sleep 2
        else
            success "NetworkManager is already running (default in Pi OS 2025)"
        fi

        # Note: We don't touch dhcpcd anymore - it's deprecated and causes issues
    fi

    # Step 2: Install/repair WiFi Connect
    if [ "$mode" -eq 2 ]; then
        # Force reinstall in repair mode
        install_wifi_connect true
    else
        install_wifi_connect false
    fi

    # Step 3: Update components
    update_components

    # Step 4: Update services
    update_services

    # Step 5: Create default config or restore backup
    if [ -n "$backup_file" ]; then
        restore_config "$backup_file"
    elif [ ! -f "$CONFIG_DIR/config.json" ]; then
        log "Creating default configuration..."
        cat > "$CONFIG_DIR/config.json" << EOF
{
  "startup_command": "",
  "wifi_networks": []
}
EOF
    fi

    # Step 6: Enable and restart services
    log "Enabling and restarting services..."
    # Note: wifi-connect is NOT enabled - managed by wifi-connect-manager
    systemctl enable wifi-connect-manager.service >> "$LOG_FILE" 2>&1
    systemctl enable ossuary-startup.service >> "$LOG_FILE" 2>&1
    systemctl enable ossuary-web.service >> "$LOG_FILE" 2>&1

    # Restart services (don't fail if services don't start immediately)
    log "Starting all services..."

    # Start WiFi Connect Manager (intelligently manages captive portal)
    log "Starting WiFi Connect Manager..."
    systemctl restart wifi-connect-manager 2>/dev/null || warning "WiFi Connect Manager may need manual start"
    sleep 2  # Give it time to start

    # Start web configuration server (always available on port 8080)
    log "Starting web configuration service..."
    systemctl restart ossuary-web 2>/dev/null || warning "Web service may need manual start"

    # Start startup command service (runs user's command at boot)
    log "Starting startup command service..."
    systemctl restart ossuary-startup 2>/dev/null || true  # This is oneshot, might not stay "active"

    # Step 7: Copy uninstall and fix scripts
    cp "$REPO_DIR/uninstall.sh" "$INSTALL_DIR/" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true

    if [ -f "$REPO_DIR/fix-wifi-connect.sh" ]; then
        cp "$REPO_DIR/fix-wifi-connect.sh" "$INSTALL_DIR/" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/fix-wifi-connect.sh" 2>/dev/null || true
    fi

    # Step 8: Verify installation
    log "Verifying installation..."
    local issues=0

    if ! command -v wifi-connect &> /dev/null; then
        warning "WiFi Connect binary not found"
        issues=$((issues + 1))
    fi

    if ! systemctl is-active --quiet wifi-connect; then
        warning "WiFi Connect service is not running"
        issues=$((issues + 1))
    fi

    if ! systemctl is-active --quiet ossuary-web; then
        warning "Web configuration service is not running"
        issues=$((issues + 1))
    fi

    if [ $issues -eq 0 ]; then
        success "All components verified successfully!"
    else
        warning "$issues component(s) may need attention"
    fi

    # Return 0 even if there are issues (non-fatal)
    return 0
}

# SSH safety wrapper (simplified for updates)
run_ssh_safe() {
    echo ""
    echo -e "${YELLOW}Installation will continue in background.${NC}"
    echo "You can monitor progress with: tail -f $LOG_FILE"
    echo ""

    nohup bash -c "
        $(declare -f log error warning success backup_config restore_config install_wifi_connect update_components update_services perform_installation)
        REPO_DIR='$REPO_DIR'
        INSTALL_DIR='$INSTALL_DIR'
        CONFIG_DIR='$CONFIG_DIR'
        CUSTOM_UI_DIR='$CUSTOM_UI_DIR'
        LOG_FILE='$LOG_FILE'
        perform_installation $1
        echo 'Installation complete. System will reboot in 10 seconds...'
        sleep 10
        reboot
    " > /tmp/ossuary-install-output.log 2>&1 &

    local pid=$!
    echo "Installation running in background (PID: $pid)"

    # Monitor for a bit
    local count=0
    while [ $count -lt 10 ] && kill -0 $pid 2>/dev/null; do
        echo -n "."
        sleep 1
        count=$((count + 1))
    done

    echo ""

    if kill -0 $pid 2>/dev/null; then
        echo "Installation is running..."
        echo "Your system will reboot automatically when complete."
    else
        echo "Installation may have completed quickly. Check logs for details."
    fi
}

# Main execution
main() {
    # Initialize log first thing
    echo "Installation/Update started at $(date)" > "$LOG_FILE"
    echo "Script version: $(date -r "$0" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')" >> "$LOG_FILE"
    echo "Running as: $(whoami)" >> "$LOG_FILE"
    echo "Current directory: $(pwd)" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"

    clear
    echo "==========================================="
    echo "    ___                                  "
    echo "   / _ \\__ ____ ___ _____ _____ _____  "
    echo "  | | | / _/ __|| | | / _  |  __| | | | "
    echo "  | |_| \\__ \\__ \\ |_| | (_| | |  | |_| |"
    echo "   \\___/__/____/\\__,_|\\__,_|_|   \\__, |"
    echo "                                    __/ |"
    echo "       Raspberry Pi Edition        |___/ "
    echo "==========================================="
    echo "    WiFi Failover & Configuration System"
    echo "==========================================="
    echo ""

    # Check root
    log "Checking root privileges..."
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: Not running as root (EUID=$EUID)"
        error "This script must be run as root (use sudo)"
    fi
    log "Running as root - OK"

    # Check Pi OS version
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log "Detected OS: $PRETTY_NAME"

        # Check if it's Raspberry Pi OS
        if [[ "$ID" == "raspbian" ]] || [[ "$ID" == "debian" ]]; then
            # Check Debian version
            if [[ "$VERSION_ID" -ge "12" ]]; then
                success "Running on Debian $VERSION_ID (Bookworm or newer) - fully compatible"
            elif [[ "$VERSION_ID" == "11" ]]; then
                warning "Debian 11 (Bullseye) detected - should work but consider upgrading"
            else
                warning "Older Debian version detected - may have compatibility issues"
            fi
        fi
    fi

    # Check WiFi interface (non-fatal for updates)
    log "Detecting WiFi interface..."

    # Method 1: ip link
    WIFI_INTERFACE=$(ip link 2>/dev/null | grep -E '^[0-9]+: wl' | cut -d: -f2 | tr -d ' ' | head -n1 || true)

    if [ -z "$WIFI_INTERFACE" ]; then
        log "Method 1 failed, trying iw dev..."
        # Method 2: iw dev
        if command -v iw &>/dev/null; then
            WIFI_INTERFACE=$(iw dev 2>/dev/null | awk '/Interface/ {print $2}' | head -n1 || true)
        fi
    fi

    if [ -z "$WIFI_INTERFACE" ]; then
        log "Method 2 failed, checking /sys/class/net..."
        # Method 3: /sys/class/net
        WIFI_INTERFACE=$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -n1 || true)
    fi

    if [ -n "$WIFI_INTERFACE" ]; then
        success "WiFi interface detected: $WIFI_INTERFACE"
    else
        warning "Could not detect WiFi interface name (WiFi Connect will auto-detect)"
        log "WiFi detection methods tried but failed - this is non-fatal"
    fi

    # Check existing installation
    log "Starting installation check..."
    check_existing_installation
    local mode=$?
    log "Installation mode determined: $mode (0=fresh, 1=update, 2=repair)"

    # Handle based on mode
    case $mode in
        0)  # Fresh install
            echo "No existing installation found."
            echo "This will install Ossuary Pi with WiFi failover."
            ;;
        1)  # Update
            echo ""
            echo "This will update your existing installation:"
            echo "  • Update WiFi Connect binary"
            echo "  • Refresh custom UI"
            echo "  • Update all scripts"
            echo "  • Preserve your configuration"
            ;;
        2)  # Repair
            echo ""
            echo "Detected broken components. This will:"
            echo "  • Reinstall WiFi Connect binary"
            echo "  • Fix broken services"
            echo "  • Preserve your configuration"
            ;;
    esac

    # Check for SSH session
    if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
        if [ $mode -eq 0 ]; then
            # Fresh install - full SSH warning
            echo ""
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}         SSH SESSION DETECTED - IMPORTANT        ${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "This installation will:"
            echo "  1. Ensure NetworkManager is running"
            echo "  2. Install WiFi Connect and dependencies"
            echo "  3. Configure services"
            echo -e "  4. ${YELLOW}REBOOT YOUR SYSTEM AUTOMATICALLY${NC}"
            echo ""
            echo -e "${YELLOW}Your SSH connection WILL be disconnected.${NC}"
            echo ""
            echo "The installation will continue even if SSH disconnects."
            echo "The system will automatically reboot when complete."
            echo ""
            echo -e "${BLUE}After reboot:${NC}"
            echo "  • Look for 'Ossuary-Setup' WiFi network if no WiFi found"
            echo "  • Or SSH back in using the same IP address"
            echo "  • Access config at http://$(hostname)"
        else
            # Update/repair - lighter warning
            echo ""
            echo -e "${YELLOW}SSH session detected!${NC}"
            echo "Update/repair can be done without losing connection."
            echo "No reboot required unless you choose to."
        fi
    else
        # Local installation - show what will happen
        if [ $mode -eq 0 ]; then
            echo ""
            echo "This will:"
            echo "  • Install required packages"
            echo "  • Configure NetworkManager"
            echo "  • Install WiFi Connect"
            echo "  • Set up web configuration interface"
            echo "  • Create systemd services"
            echo ""
            echo "You'll need to reboot after installation."
        fi
    fi

    echo ""
    echo -n "Do you want to continue? (yes/no): "
    read -r response
    log "User response: $response"

    if [ "$response" != "yes" ]; then
        log "Installation cancelled by user"
        echo "Installation cancelled."
        echo ""
        echo "Log file: $LOG_FILE"
        exit 0
    fi

    log "User confirmed - proceeding with installation"

    echo ""

    # Run installation based on context
    if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
        if [ $mode -eq 0 ]; then
            # Fresh install over SSH - use background wrapper
            run_ssh_safe $mode
        else
            # Update/repair over SSH - run directly (no reboot)
            perform_installation $mode
            local result=$?
            if [ $result -eq 0 ]; then
                echo ""
                echo "==========================================="
                echo -e "${GREEN}    Installation Complete!${NC}"
                echo "==========================================="
                echo ""
                if [ $mode -eq 1 ]; then
                    echo "Your installation has been updated successfully."
                else
                    echo "Repair completed successfully."
                fi
                echo ""
                echo "Services status:"

                # Check each service
                if systemctl is-active --quiet wifi-connect; then
                    echo -e "  ${GREEN}✓${NC} WiFi Connect (captive portal) - Running"
                else
                    echo -e "  ${RED}✗${NC} WiFi Connect - Not running (run: sudo systemctl start wifi-connect)"
                fi

                if systemctl is-active --quiet ossuary-web; then
                    echo -e "  ${GREEN}✓${NC} Web config server - Running on port 80"
                else
                    echo -e "  ${RED}✗${NC} Web config server - Not running (run: sudo systemctl start ossuary-web)"
                fi

                if [ -f "$CONFIG_DIR/config.json" ]; then
                    echo -e "  ${GREEN}✓${NC} Configuration file exists"
                else
                    echo -e "  ${YELLOW}⚠${NC} No configuration file yet"
                fi

                echo ""
                echo "Access points:"
                echo "  • Config page: http://$(hostname):8080 or http://$(hostname -I | awk '{print $1}'):8080"
                echo "  • If no WiFi: Look for 'Ossuary-Setup' network"
                echo ""
                echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${BLUE}         USEFUL COMMANDS TO REMEMBER              ${NC}"
                echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                echo "📊 Check Status:"
                echo "  sudo systemctl status wifi-connect      # WiFi/AP service"
                echo "  sudo systemctl status ossuary-web       # Config web server"
                echo "  sudo systemctl status ossuary-startup   # Startup command service"
                echo "  ./check-status.sh                       # Overall system status"
                echo ""
                echo "📝 View Logs:"
                echo "  journalctl -u wifi-connect -f          # WiFi Connect logs (live)"
                echo "  journalctl -u ossuary-web -f           # Web server logs (live)"
                echo "  journalctl -u ossuary-startup          # Startup command logs"
                echo "  cat /var/log/ossuary-startup.log       # Startup command output"
                echo ""
                echo "🔧 Manage Services:"
                echo "  sudo systemctl restart wifi-connect    # Restart WiFi/AP service"
                echo "  sudo systemctl restart ossuary-web     # Restart config server"
                echo "  sudo systemctl stop wifi-connect       # Stop WiFi service"
                echo "  sudo systemctl start wifi-connect      # Start WiFi service"
                echo ""
                echo "🌐 Network Commands:"
                echo "  nmcli device wifi list                 # List WiFi networks"
                echo "  nmcli device status                    # Show network status"
                echo "  iwgetid                                # Show current WiFi SSID"
                echo "  hostname -I                            # Show IP address"
                echo ""
                echo "🔄 Force AP Mode (for testing):"
                echo "  sudo nmcli device disconnect wlan0     # Disconnect WiFi"
                echo "  sudo systemctl restart wifi-connect    # Restart to trigger AP"
                echo ""
                echo "📁 Configuration:"
                echo "  cat /etc/ossuary/config.json          # View config file"
                echo "  nano /etc/ossuary/config.json         # Edit config manually"
                echo ""
                echo "🗑️  Uninstall:"
                echo "  sudo ./uninstall.sh                   # Remove Ossuary"
                echo ""
                echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                echo "No reboot required - services are running!"
            fi
        fi
    else
        # Local installation - run directly
        perform_installation $mode
        local result=$?
        if [ $result -eq 0 ]; then
            echo ""
            echo "==========================================="
            echo -e "${GREEN}    Installation Complete!${NC}"
            echo "==========================================="
            echo ""

            if [ $mode -eq 0 ]; then
                echo "Please reboot your system to complete setup:"
                echo "  sudo reboot"
            else
                echo "Update/repair complete. Services have been restarted."
            fi

            echo ""
            echo "After reboot:"
            echo "  • If no WiFi: Look for 'Ossuary-Setup' network"
            echo "  • If connected: Access config at http://$(hostname):8080"
            echo ""
            echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BLUE}         COMMANDS REFERENCE (SAVE THIS!)          ${NC}"
            echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "After reboot, use these commands:"
            echo ""
            echo "Check if services are running:"
            echo "  sudo systemctl status wifi-connect ossuary-web"
            echo ""
            echo "View logs if something's wrong:"
            echo "  sudo journalctl -u wifi-connect -n 50"
            echo "  sudo journalctl -u ossuary-web -n 50"
            echo ""
            echo "Force AP mode for testing:"
            echo "  sudo nmcli device disconnect wlan0"
            echo "  sudo systemctl restart wifi-connect"
            echo ""
            echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "${BLUE}Thank you for using Ossuary Pi!${NC}"
        fi
    fi
}

# Quick sanity check before running
if [ ! -f "$REPO_DIR/install.sh" ]; then
    echo "Error: Cannot find install.sh in current directory"
    echo "Please run from the ossuary-pi directory"
    exit 1
fi

# Run main function and capture any exit
log_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "" >> "$LOG_FILE" 2>/dev/null
        echo "Script exited with code: $exit_code" >> "$LOG_FILE" 2>/dev/null
        echo ""
        echo -e "${RED}Installation failed. Check the log for details:${NC}"
        echo "  cat $LOG_FILE"
        echo ""
        echo "For verbose output, run with: DEBUG=1 sudo ./install.sh"
    fi
}

trap log_exit EXIT

# Handle Ctrl+C gracefully
trap 'echo -e "\n${YELLOW}Installation interrupted by user${NC}"; exit 130' INT

# Run main function
main "$@"