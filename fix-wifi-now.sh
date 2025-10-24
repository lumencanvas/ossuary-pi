#!/bin/bash

# Emergency WiFi fix script
echo "==================================="
echo "Emergency WiFi Connection Fix"
echo "==================================="
echo ""

# 1. Stop WiFi Connect immediately - it may be blocking
echo "1. Stopping WiFi Connect service..."
sudo systemctl stop wifi-connect
sudo systemctl stop wifi-connect-manager
echo "   Done"
echo ""

# 2. Restart NetworkManager
echo "2. Restarting NetworkManager..."
sudo systemctl restart NetworkManager
sleep 3
echo "   Done"
echo ""

# 3. Ensure WiFi is enabled
echo "3. Enabling WiFi radio..."
sudo nmcli radio wifi on
sleep 2
echo "   Done"
echo ""

# 4. Make sure wlan0 is managed
echo "4. Setting wlan0 to managed..."
sudo nmcli device set wlan0 managed yes
sleep 1
echo "   Done"
echo ""

# 5. Scan for networks
echo "5. Scanning for WiFi networks..."
sudo nmcli device wifi rescan
sleep 3
sudo nmcli device wifi list
echo ""

# 6. Show saved connections
echo "6. Saved WiFi connections:"
nmcli connection show | grep wifi
echo ""

# 7. Try to connect
echo "7. Attempting automatic connection..."
sudo nmcli device connect wlan0 2>&1 || true
sleep 5

# Check status
if iwgetid -r >/dev/null 2>&1; then
    ssid=$(iwgetid -r)
    echo ""
    echo "✓ SUCCESS: Connected to $ssid"
    echo ""

    # Fix the services for next boot
    echo "8. Updating services for proper boot behavior..."

    # Copy the fixed wifi-connect-manager.sh if it exists
    if [ -f "/Users/obsidian/Projects/ossuary-dev/ossuary-pi/scripts/wifi-connect-manager.sh" ]; then
        sudo cp /Users/obsidian/Projects/ossuary-dev/ossuary-pi/scripts/wifi-connect-manager.sh /opt/ossuary/scripts/
        echo "   Updated wifi-connect-manager.sh"
    fi

    # Restart the manager with the fix
    sudo systemctl start wifi-connect-manager
    echo "   Started wifi-connect-manager"
else
    echo ""
    echo "✗ Still not connected. Try manually:"
    echo ""

    # Get list of saved networks and try each
    echo "Attempting each saved network manually..."
    for conn in $(nmcli -t -f NAME connection show | grep -v "lo\|eth"); do
        echo "  Trying: $conn"
        sudo nmcli connection up "$conn" 2>&1 | grep -E "success|Error|Failed" || true
        sleep 2
        if iwgetid -r >/dev/null 2>&1; then
            echo "  ✓ Connected via $conn"
            break
        fi
    done
fi

echo ""
echo "==================================="
echo "Current Status:"
echo "==================================="
iwgetid 2>/dev/null || echo "No WiFi connection"
ip addr show wlan0 | grep "inet " || echo "No IP address"

echo ""
echo "If still not connected, manually connect with:"
echo "  sudo nmcli device wifi connect 'YOUR_SSID' password 'YOUR_PASSWORD'"
echo ""
echo "To see available networks:"
echo "  sudo nmcli device wifi list"