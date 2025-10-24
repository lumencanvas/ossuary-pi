#!/bin/bash

# Quick fix for the --gateway-interface error

echo "Fixing WiFi Connect service..."

# Remove the invalid flag
sudo sed -i 's/--gateway-interface wlan0//' /etc/systemd/system/wifi-connect.service

# Clean up any double backslashes or spaces
sudo sed -i 's/\\\\$/\\/' /etc/systemd/system/wifi-connect.service

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart wifi-connect

echo "Fixed! Checking status..."
sudo systemctl status wifi-connect --no-pager

echo ""
echo "Service should now be running without errors."