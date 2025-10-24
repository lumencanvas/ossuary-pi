#!/bin/bash

# Fix script for WiFi Connect binary installation
# Run this if wifi-connect service fails with "No such file or directory"

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "======================================"
echo "  WiFi Connect Binary Fix Script"
echo "======================================"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Detect architecture
ARCH=$(uname -m)
WIFI_CONNECT_VERSION="v4.11.84"
DOWNLOAD_URL=""

case "$ARCH" in
    "aarch64"|"arm64")
        DOWNLOAD_URL="https://github.com/balena-os/wifi-connect/releases/download/${WIFI_CONNECT_VERSION}/wifi-connect-aarch64-unknown-linux-gnu.tar.gz"
        echo "Detected ARM64 (Pi 4/5)"
        ;;
    "armv7l"|"armhf")
        DOWNLOAD_URL="https://github.com/balena-os/wifi-connect/releases/download/${WIFI_CONNECT_VERSION}/wifi-connect-armv7-unknown-linux-gnueabihf.tar.gz"
        echo "Detected ARMv7 (Pi 3/Zero 2 W)"
        ;;
    *)
        echo -e "${RED}Unsupported architecture: $ARCH${NC}"
        exit 1
        ;;
esac

echo ""
echo "Downloading WiFi Connect ${WIFI_CONNECT_VERSION}..."
cd /tmp
wget -q --show-progress "$DOWNLOAD_URL" -O wifi-connect.tar.gz

echo "Extracting..."
tar -xzf wifi-connect.tar.gz

echo "Installing to /usr/local/bin/..."
mv wifi-connect /usr/local/bin/
chmod +x /usr/local/bin/wifi-connect

echo "Verifying installation..."
if [ -f /usr/local/bin/wifi-connect ]; then
    echo -e "${GREEN}WiFi Connect binary installed successfully!${NC}"

    # Check if it runs
    if /usr/local/bin/wifi-connect --version &>/dev/null; then
        echo -e "${GREEN}Binary is executable and working${NC}"
    else
        echo -e "${YELLOW}Binary installed but may have dependency issues${NC}"
        echo "Checking dependencies..."
        ldd /usr/local/bin/wifi-connect || true
    fi
else
    echo -e "${RED}Installation failed!${NC}"
    exit 1
fi

echo ""
echo "Restarting wifi-connect service..."
systemctl daemon-reload
systemctl restart wifi-connect

sleep 2

echo ""
echo "Checking service status..."
if systemctl is-active --quiet wifi-connect; then
    echo -e "${GREEN}Service is running!${NC}"
    echo ""
    echo "WiFi Connect fixed successfully!"
    echo "If no WiFi is configured, look for 'Ossuary-Setup' network"
else
    echo -e "${YELLOW}Service may still have issues. Checking logs...${NC}"
    journalctl -u wifi-connect -n 20 --no-pager
fi

echo ""
echo "======================================"
echo "Fix complete. Current status:"
systemctl status wifi-connect --no-pager -l

exit 0