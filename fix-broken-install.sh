#!/bin/bash

# Fix/Upgrade script for broken Ossuary Pi installations
# This properly cleans up and reinstalls with all fixes

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "======================================"
echo "  Ossuary Pi Fix/Upgrade Script"
echo "======================================"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

echo -e "${YELLOW}This will fix your broken Ossuary Pi installation${NC}"
echo "It will:"
echo "  • Stop all running services"
echo "  • Clean up old configurations"
echo "  • Re-run the installer with all fixes"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo -e "${YELLOW}Step 1: Stopping all services...${NC}"

# Stop all services (ignore errors if they don't exist)
systemctl stop wifi-connect 2>/dev/null || true
systemctl stop wifi-connect-manager 2>/dev/null || true
systemctl stop ossuary-web 2>/dev/null || true
systemctl stop ossuary-startup 2>/dev/null || true

# Disable the broken wifi-connect auto-start
systemctl disable wifi-connect 2>/dev/null || true

echo -e "${GREEN}✓ Services stopped${NC}"

echo ""
echo -e "${YELLOW}Step 2: Cleaning up old configurations...${NC}"

# Remove old service files to ensure clean reinstall
rm -f /etc/systemd/system/wifi-connect.service
rm -f /etc/systemd/system/wifi-connect-manager.service
rm -f /etc/systemd/system/ossuary-web.service
rm -f /etc/systemd/system/ossuary-startup.service

# Reload systemd
systemctl daemon-reload

echo -e "${GREEN}✓ Old configurations removed${NC}"

echo ""
echo -e "${YELLOW}Step 3: Ensuring NetworkManager is properly configured...${NC}"

# Make sure NetworkManager is running (critical for WiFi persistence)
if ! systemctl is-active --quiet NetworkManager; then
    systemctl enable NetworkManager
    systemctl start NetworkManager
    sleep 2
    echo -e "${GREEN}✓ NetworkManager started${NC}"
else
    echo -e "${GREEN}✓ NetworkManager already running${NC}"
fi

echo ""
echo -e "${YELLOW}Step 4: Running installer with all fixes...${NC}"

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check if install.sh exists
if [ ! -f "$SCRIPT_DIR/install.sh" ]; then
    echo -e "${RED}Error: install.sh not found in $SCRIPT_DIR${NC}"
    echo "Please run this from the ossuary-pi directory"
    exit 1
fi

# Make sure scripts are executable
chmod +x "$SCRIPT_DIR/install.sh" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/wifi-connect-manager.sh" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/process-manager.sh" 2>/dev/null || true

# Run the installer (it will handle updates properly)
echo ""
cd "$SCRIPT_DIR"
./install.sh --update

echo ""
echo "======================================"
echo -e "${GREEN}Fix completed!${NC}"
echo "======================================"
echo ""
echo "What's been fixed:"
echo "  ✅ WiFi Connect only runs when needed (not always)"
echo "  ✅ WiFi networks will persist after connection"
echo "  ✅ Process manager properly kills all child processes"
echo "  ✅ SSID selection works in captive portal"
echo "  ✅ Control panel on port 8080, captive portal on port 80"
echo ""
echo "Next steps:"
echo "  1. The system will check for WiFi connection"
echo "  2. If no WiFi found, look for 'Ossuary-Setup' network"
echo "  3. If WiFi is connected, access control panel at:"
echo "     http://$(hostname -I | awk '{print $1}'):8080"
echo ""
echo "To check status:"
echo "  sudo systemctl status wifi-connect-manager"
echo "  sudo systemctl status ossuary-web"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u wifi-connect-manager -f"
echo ""

exit 0