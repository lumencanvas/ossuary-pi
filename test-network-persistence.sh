#!/bin/bash

# Test script to verify network persistence fixes

echo "=========================================="
echo "Network Persistence Test"
echo "=========================================="
echo ""

# Check for saved networks
echo "Checking for saved WiFi networks..."
if command -v nmcli >/dev/null; then
    echo "NetworkManager saved networks:"
    nmcli -t -f TYPE,NAME,AUTOCONNECT connection show | grep "802-11-wireless"
    echo ""

    # Count saved networks
    saved_count=$(nmcli -t -f TYPE,NAME connection show 2>/dev/null | grep -c "^802-11-wireless:")
    echo "Total saved WiFi networks: $saved_count"
else
    echo "NetworkManager not found"
fi

echo ""

# Check wpa_supplicant
if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    echo "wpa_supplicant configuration:"
    grep "ssid=" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null | head -5
fi

echo ""

# Check current connection
echo "Current WiFi status:"
if iwgetid -r >/dev/null 2>&1; then
    ssid=$(iwgetid -r)
    if [ -n "$ssid" ]; then
        echo "Connected to: $ssid"
    else
        echo "Not connected to any WiFi network"
    fi
else
    echo "Unable to check WiFi status"
fi

echo ""

# Check if wifi-connect-manager is running
echo "Service status:"
if systemctl is-active --quiet wifi-connect-manager; then
    echo "✓ wifi-connect-manager is running"
else
    echo "✗ wifi-connect-manager is not running"
fi

if systemctl is-active --quiet wifi-connect; then
    echo "✓ wifi-connect (AP mode) is running"
else
    echo "✗ wifi-connect (AP mode) is not running"
fi

echo ""
echo "=========================================="
echo "To manually test network persistence:"
echo "1. Connect to a WiFi network through the captive portal"
echo "2. Run: sudo /opt/ossuary/scripts/ensure-network-persistence.sh"
echo "3. Reboot the system"
echo "4. Check if it reconnects automatically (should not open AP)"
echo "=========================================="