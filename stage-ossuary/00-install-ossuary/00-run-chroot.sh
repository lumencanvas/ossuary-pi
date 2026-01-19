#!/bin/bash -e

# This runs inside the Pi image filesystem (chroot)
# Configure Ossuary for first boot

on_chroot << EOF
#!/bin/bash -e

echo "Installing Ossuary Pi..."

# Run the install script in image-build mode
# This skips things like rebooting and network checks
cd /opt/ossuary
if [ -f install.sh ]; then
    # Set flag to indicate we're in image build mode
    export OSSUARY_IMAGE_BUILD=1

    # Run install with --image-build flag if supported, otherwise run normally
    if grep -q "image-build" install.sh 2>/dev/null; then
        ./install.sh --image-build || true
    else
        # Manual installation steps for image build

        # Create config directory
        mkdir -p /etc/ossuary

        # Create empty config (user will configure via welcome page)
        cat > /etc/ossuary/config.json << 'CONFIGEOF'
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

        # Install systemd services
        if [ -d /opt/ossuary/services ]; then
            cp /opt/ossuary/services/*.service /etc/systemd/system/ 2>/dev/null || true
        fi

        # Enable services (they'll start on first boot)
        systemctl enable ossuary-startup.service 2>/dev/null || true
        systemctl enable ossuary-web.service 2>/dev/null || true
        systemctl enable wifi-connect-manager.service 2>/dev/null || true
        systemctl enable ossuary-connection-monitor.service 2>/dev/null || true

        # Disable conflicting services
        systemctl disable wpa_supplicant.service 2>/dev/null || true
        systemctl mask wpa_supplicant.service 2>/dev/null || true

        # Enable NetworkManager
        systemctl enable NetworkManager.service 2>/dev/null || true
    fi
fi

# Configure auto-login for kiosk mode
if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_boot_behaviour B4 || true
fi

# Disable SSH warning popups
rm -f /etc/profile.d/sshpwd.sh 2>/dev/null || true
rm -f /etc/xdg/lxsession/LXDE-pi/sshpwd.sh 2>/dev/null || true
rm -f /etc/xdg/autostart/piwiz.desktop 2>/dev/null || true

# Disable screen blanking
if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_blanking 1 || true
fi

echo "Ossuary Pi installation complete!"
EOF
