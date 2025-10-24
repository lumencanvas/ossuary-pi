#!/bin/bash

echo "==================================="
echo "WiFi Connection Emergency Diagnostic"
echo "==================================="
echo ""

# 1. Check what's actually happening
echo "1. Current WiFi Status:"
echo "----------------------"
iwgetid 2>/dev/null || echo "No WiFi connection"
echo ""

# 2. NetworkManager status
echo "2. NetworkManager Status:"
echo "------------------------"
systemctl status NetworkManager --no-pager | head -10
echo ""

# 3. Saved networks
echo "3. Saved Networks:"
echo "-----------------"
nmcli connection show | grep wifi
echo ""

# 4. Available networks
echo "4. Available WiFi Networks:"
echo "--------------------------"
nmcli device wifi list
echo ""

# 5. WiFi Connect status
echo "5. WiFi Connect Service Status:"
echo "-------------------------------"
systemctl status wifi-connect --no-pager | head -10
echo ""

# 6. WiFi Connect Manager status
echo "6. WiFi Connect Manager Status:"
echo "-------------------------------"
systemctl status wifi-connect-manager --no-pager | head -10
echo ""

# 7. Recent logs
echo "7. Recent WiFi Connect Manager Logs:"
echo "------------------------------------"
journalctl -u wifi-connect-manager -n 20 --no-pager
echo ""

echo "8. Recent WiFi Connect Logs:"
echo "----------------------------"
journalctl -u wifi-connect -n 20 --no-pager
echo ""

# 9. Network interface status
echo "9. Network Interface Status:"
echo "---------------------------"
ip link show wlan0
echo ""
ifconfig wlan0 2>/dev/null || ip addr show wlan0
echo ""

# 10. Check if WiFi Connect is blocking NetworkManager
echo "10. Process Check:"
echo "-----------------"
ps aux | grep -E "wifi-connect|NetworkManager|wpa_supplicant" | grep -v grep
echo ""

echo "==================================="
echo "Quick Fix Attempts:"
echo "==================================="
echo ""

echo "Stopping WiFi Connect to let NetworkManager take over..."
sudo systemctl stop wifi-connect

echo "Restarting NetworkManager..."
sudo systemctl restart NetworkManager

sleep 3

echo "Attempting to connect to saved networks..."
for conn in $(nmcli -t -f NAME connection show | grep -v "Wired"); do
    echo "Trying: $conn"
    sudo nmcli connection up "$conn" 2>&1 | head -5
done

echo ""
echo "Current status after fixes:"
iwgetid 2>/dev/null || echo "Still no connection"

echo ""
echo "==================================="
echo "Manual Fix Commands:"
echo "==================================="
echo "1. Force stop WiFi Connect:"
echo "   sudo systemctl stop wifi-connect"
echo ""
echo "2. Connect manually to a saved network:"
echo "   sudo nmcli connection up 'YourNetworkName'"
echo ""
echo "3. Restart everything:"
echo "   sudo systemctl restart NetworkManager"
echo "   sudo systemctl restart wifi-connect-manager"
echo ""
echo "4. If all else fails, reconfigure:"
echo "   sudo nmcli device wifi connect 'SSID' password 'PASSWORD'"
echo "==================================="