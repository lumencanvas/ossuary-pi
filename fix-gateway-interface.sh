#!/bin/bash

# Fix for the --gateway-interface error in WiFi Connect service
# This flag doesn't exist and causes WiFi Connect to fail

echo "Fixing WiFi Connect service configuration..."
echo "Removing invalid --gateway-interface flag..."

# Check if the service file exists
if [ ! -f /etc/systemd/system/wifi-connect.service ]; then
    echo "Error: WiFi Connect service file not found!"
    echo "Please run the installer first: sudo ./install.sh"
    exit 1
fi

# Check if the invalid flag is present
if grep -q "gateway-interface" /etc/systemd/system/wifi-connect.service; then
    echo "Found --gateway-interface flag, removing it..."

    # Remove the invalid flag
    sudo sed -i 's/--gateway-interface [^ ]*//g' /etc/systemd/system/wifi-connect.service

    # Also remove any line that only has --gateway-interface
    sudo sed -i '/^\s*--gateway-interface/d' /etc/systemd/system/wifi-connect.service

    # Clean up any double spaces or trailing backslashes
    sudo sed -i 's/  */ /g' /etc/systemd/system/wifi-connect.service
    sudo sed -i 's/ \\$/\\/' /etc/systemd/system/wifi-connect.service

    echo "Fixed! Reloading systemd and restarting service..."

    # Reload systemd and restart the service
    sudo systemctl daemon-reload
    sudo systemctl restart wifi-connect

    echo ""
    echo "Service has been fixed and restarted."
    echo ""
else
    echo "No --gateway-interface flag found. Service configuration is correct."
fi

# Show current status
echo "Current WiFi Connect service status:"
sudo systemctl status wifi-connect --no-pager

echo ""
echo "Current service configuration:"
echo "--------------------------------"
grep "ExecStart" /etc/systemd/system/wifi-connect.service

echo ""
echo "If you still have issues, check the logs with:"
echo "  sudo journalctl -u wifi-connect -n 50"