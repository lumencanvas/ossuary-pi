#!/bin/bash -e

# Combined host and chroot script for installing Ossuary
# This avoids potential issues with separate run-chroot.sh files

echo "=== Ossuary Pi Installation ==="
echo "ROOTFS_DIR: ${ROOTFS_DIR}"
echo "PWD: $(pwd)"

# Verify ROOTFS_DIR exists
if [ ! -d "${ROOTFS_DIR}" ]; then
    echo "ERROR: ROOTFS_DIR does not exist: ${ROOTFS_DIR}"
    ls -la "$(dirname "${ROOTFS_DIR}")" || true
    exit 1
fi

echo "ROOTFS_DIR exists, listing contents:"
ls -la "${ROOTFS_DIR}" | head -20

# === HOST OPERATIONS ===
# Create directories
install -d "${ROOTFS_DIR}/opt/ossuary"
install -d "${ROOTFS_DIR}/etc/ossuary"

# Copy all ossuary files from the repo
if [ -d "files/ossuary-pi" ]; then
    echo "Copying ossuary-pi files to rootfs..."
    cp -rv files/ossuary-pi/* "${ROOTFS_DIR}/opt/ossuary/"
else
    echo "WARNING: files/ossuary-pi not found"
    ls -la files/ || echo "files/ directory not found"
fi

# Make scripts executable
chmod +x "${ROOTFS_DIR}/opt/ossuary/install.sh" 2>/dev/null || true
chmod +x "${ROOTFS_DIR}/opt/ossuary/scripts/"*.sh 2>/dev/null || true
chmod +x "${ROOTFS_DIR}/opt/ossuary/scripts/"*.py 2>/dev/null || true

echo "Host operations complete. ROOTFS_DIR still exists:"
ls -la "${ROOTFS_DIR}" | head -10

# === CHROOT OPERATIONS ===
echo "Starting chroot operations..."

# Final verification before chroot - this is where the original error occurred
echo "=== Pre-chroot verification ==="
echo "ROOTFS_DIR: ${ROOTFS_DIR}"
if [ ! -d "${ROOTFS_DIR}" ]; then
    echo "FATAL: ROOTFS_DIR disappeared before chroot!"
    exit 1
fi

# Verify key directories exist (these are needed for on_chroot mounts)
for dir in proc dev sys; do
    if [ ! -d "${ROOTFS_DIR}/${dir}" ]; then
        echo "WARNING: ${ROOTFS_DIR}/${dir} does not exist, creating..."
        mkdir -p "${ROOTFS_DIR}/${dir}"
    fi
done

# Also ensure /run and /tmp exist
for dir in run tmp; do
    if [ ! -d "${ROOTFS_DIR}/${dir}" ]; then
        echo "WARNING: ${ROOTFS_DIR}/${dir} does not exist, creating..."
        mkdir -p "${ROOTFS_DIR}/${dir}"
    fi
done

echo "Rootfs directory structure verified:"
ls -la "${ROOTFS_DIR}" | head -15
echo "=== Starting on_chroot ==="

on_chroot << 'CHROOT_EOF'
set -e

INSTALL_DIR="/opt/ossuary"
CUSTOM_UI_DIR="/opt/ossuary/custom-ui"
CONFIG_DIR="/etc/ossuary"

echo "Installing Ossuary Pi (inside chroot)..."

# Create directories
mkdir -p "$CONFIG_DIR"
mkdir -p /run/ossuary
mkdir -p /var/lib/ossuary

# Create empty config (user will configure via welcome page or Pi Imager WiFi)
cat > "$CONFIG_DIR/config.json" << 'CONFIGEOF'
{
  "startup_command": "",
  "saved_networks": [],
  "behaviors": {
    "on_connection_lost": {"action": "show_overlay"},
    "on_connection_regained": {"action": "refresh_page"},
    "scheduled_refresh": {"enabled": false, "interval_minutes": 60}
  }
}
CONFIGEOF

# Make scripts executable
chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/"*.py 2>/dev/null || true

# Create symlink for process-manager at root level
ln -sf "$INSTALL_DIR/scripts/process-manager.sh" "$INSTALL_DIR/process-manager.sh" 2>/dev/null || true

# Create systemd services

# WiFi Connect service
cat > /etc/systemd/system/wifi-connect.service << EOF
[Unit]
Description=Balena WiFi Connect - Captive Portal (only when disconnected)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wifi-connect \
    --portal-ssid "Ossuary-Setup" \
    --ui-directory $CUSTOM_UI_DIR \
    --activity-timeout 600 \
    --portal-listening-port 8080
Restart=no
Environment="DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"

[Install]
EOF

# Captive Portal Proxy
cat > /etc/systemd/system/captive-portal-proxy.service << EOF
[Unit]
Description=Captive Portal Detection Proxy
After=NetworkManager.service wifi-connect.service
Wants=wifi-connect.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/scripts/captive-portal-proxy.py
Restart=always
RestartSec=5
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=captive-portal-proxy

[Install]
WantedBy=multi-user.target
EOF

# Process manager service
cat > /etc/systemd/system/ossuary-startup.service << EOF
[Unit]
Description=Ossuary Process Manager - Keeps User Command Running
After=multi-user.target NetworkManager.service ossuary-web.service
Wants=network-online.target ossuary-web.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStart=$INSTALL_DIR/process-manager.sh
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=180
RuntimeDirectory=ossuary
RuntimeDirectoryMode=0755
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

# WiFi Connect Manager
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
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Web configuration service (port 8081 to avoid conflict with wifi-connect on 8080)
cat > /etc/systemd/system/ossuary-web.service << EOF
[Unit]
Description=Ossuary Web Configuration Interface
After=network-online.target wifi-connect-manager.service
Wants=network-online.target
BindsTo=wifi-connect-manager.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/scripts/config-server.py --port 8081
Restart=always
RestartSec=10
User=root
WorkingDirectory=$INSTALL_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Connection monitor service
cat > /etc/systemd/system/ossuary-connection-monitor.service << EOF
[Unit]
Description=Ossuary Connection Monitor
After=network-online.target ossuary-startup.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/scripts/connection-monitor.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ossuary-connection

[Install]
WantedBy=multi-user.target
EOF

# Enable services (they'll start on first boot)
systemctl enable wifi-connect-manager.service
systemctl enable captive-portal-proxy.service
systemctl enable ossuary-startup.service
systemctl enable ossuary-web.service
systemctl enable ossuary-connection-monitor.service

# Disable conflicting services
systemctl disable wpa_supplicant.service 2>/dev/null || true
systemctl mask wpa_supplicant.service 2>/dev/null || true

# Enable NetworkManager
systemctl enable NetworkManager.service

# Configure auto-login for kiosk mode
if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_boot_behaviour B4 || true
fi

# Disable SSH warning popups
rm -f /etc/profile.d/sshpwd.sh 2>/dev/null || true
rm -f /etc/xdg/lxsession/LXDE-pi/sshpwd.sh 2>/dev/null || true

# Disable piwiz (first-run wizard)
rm -f /etc/xdg/autostart/piwiz.desktop 2>/dev/null || true

# NOTE: We intentionally do NOT create .skip-userconf files here.
# This allows Pi Imager customizations (WiFi, hostname, SSH keys) to work properly.
# The firstrun.sh script from Pi Imager needs to execute to apply those settings.

# Disable screen blanking
if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_blanking 1 || true
fi

# Download and install wifi-connect binary
echo "Downloading WiFi Connect..."
WIFI_CONNECT_VERSION="v4.11.84"

# Detect architecture for wifi-connect download
if [ "$(dpkg --print-architecture)" = "arm64" ]; then
    WIFI_CONNECT_ARCH="aarch64-unknown-linux-gnu"
else
    WIFI_CONNECT_ARCH="armv7-unknown-linux-gnueabihf"
fi
echo "Detected architecture: $WIFI_CONNECT_ARCH"

DOWNLOAD_URL="https://github.com/balena-os/wifi-connect/releases/download/${WIFI_CONNECT_VERSION}/wifi-connect-${WIFI_CONNECT_ARCH}.tar.gz"

cd /tmp

# Download with retry logic
DOWNLOAD_SUCCESS=false
for attempt in 1 2 3; do
    echo "Download attempt $attempt..."
    if wget -q --timeout=60 "$DOWNLOAD_URL" -O wifi-connect.tar.gz; then
        # Verify the download is a valid gzip file
        if gzip -t wifi-connect.tar.gz 2>/dev/null; then
            DOWNLOAD_SUCCESS=true
            break
        else
            echo "Downloaded file is corrupted, retrying..."
            rm -f wifi-connect.tar.gz
        fi
    else
        echo "Download failed, retrying in 5 seconds..."
        sleep 5
    fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "ERROR: Failed to download WiFi Connect after 3 attempts"
    echo "The captive portal feature will not work without wifi-connect"
    # Don't fail the build, but log clearly
else
    tar -xzf wifi-connect.tar.gz
    mv wifi-connect /usr/local/bin/
    chmod +x /usr/local/bin/wifi-connect
    rm -f wifi-connect.tar.gz

    # Verify the binary is executable and shows version
    if /usr/local/bin/wifi-connect --version >/dev/null 2>&1; then
        echo "WiFi Connect installed successfully: $(/usr/local/bin/wifi-connect --version 2>&1 || echo 'version unknown')"
    elif command -v wifi-connect &>/dev/null; then
        echo "WiFi Connect installed (version check not available)"
    else
        echo "WARNING: WiFi Connect binary not found after installation"
    fi
fi

echo "Ossuary Pi installation complete!"
CHROOT_EOF

echo "=== Ossuary Pi Installation Complete ==="
