#!/bin/bash

# Debug script for WiFi Connect issues
# Run this when the captive portal isn't connecting properly

set +e  # Don't exit on errors, we want to see everything

echo "===== WiFi Connect Debug Script ====="
echo "Run this when networks select but don't actually connect"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    debug "Running as root - can check system files"
    IS_ROOT=true
else
    warn "Not running as root - some checks will be limited"
    IS_ROOT=false
fi

echo ""
debug "=== System Information ==="
info "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
info "Kernel: $(uname -r)"
info "Architecture: $(uname -m)"

echo ""
debug "=== WiFi Connect Service Status ==="
if systemctl is-active --quiet wifi-connect; then
    info "WiFi Connect service is running"
else
    error "WiFi Connect service is not running"
fi

if $IS_ROOT; then
    echo ""
    debug "=== Recent WiFi Connect Logs ==="
    journalctl -u wifi-connect -n 20 --no-pager
fi

echo ""
debug "=== Network Interface Status ==="
ip link show | grep -E "^[0-9]+: (wl|en)" || echo "No network interfaces found"

echo ""
debug "=== WiFi Interface Details ==="
WIFI_IFACE=$(ip link | grep -E "^[0-9]+: wl" | cut -d: -f2 | tr -d ' ' | head -1)
if [ -n "$WIFI_IFACE" ]; then
    info "Found WiFi interface: $WIFI_IFACE"
    ip addr show "$WIFI_IFACE" | head -10
else
    error "No WiFi interface found"
fi

echo ""
debug "=== NetworkManager Status ==="
if systemctl is-active --quiet NetworkManager; then
    info "NetworkManager is running"
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device status | head -10
    fi
else
    error "NetworkManager is not running"
fi

if $IS_ROOT; then
    echo ""
    debug "=== WiFi Connect Configuration ==="
    if [ -f /etc/systemd/system/wifi-connect.service ]; then
        echo "Service file exists:"
        cat /etc/systemd/system/wifi-connect.service | grep -E "ExecStart|Environment"
    else
        error "WiFi Connect service file not found"
    fi
fi

echo ""
debug "=== Custom UI Check ==="
if [ -d /opt/ossuary/custom-ui ]; then
    info "Custom UI directory exists"
    ls -la /opt/ossuary/custom-ui/
else
    error "Custom UI directory not found"
fi

echo ""
debug "=== Test WiFi Connect Endpoints ==="
if systemctl is-active --quiet wifi-connect; then
    info "Testing /networks endpoint..."
    curl -s http://localhost/networks | head -200 || error "Failed to reach /networks"

    echo ""
    info "Testing if WiFi Connect is serving on port 80..."
    curl -s -I http://localhost/ | head -5 || error "Failed to reach WiFi Connect web server"
else
    warn "WiFi Connect service not running, skipping endpoint tests"
fi

echo ""
debug "=== Common Issues & Solutions ==="
echo "1. If /networks returns empty: WiFi interface may be down"
echo "2. If /connect fails: Check password, NetworkManager status"
echo "3. If AP doesn't appear: Check wifi-connect service logs"
echo "4. If browser doesn't auto-open portal: Try http://192.168.4.1 manually"
echo ""

if $IS_ROOT; then
    echo "Troubleshooting commands:"
    echo "  # Restart WiFi Connect:     sudo systemctl restart wifi-connect"
    echo "  # Force AP mode:            sudo nmcli device disconnect $WIFI_IFACE"
    echo "  # Check live logs:          sudo journalctl -u wifi-connect -f"
    echo "  # Test WiFi scanning:       sudo iwlist $WIFI_IFACE scan | grep ESSID"
    echo ""
fi

echo "===== Debug Complete ====="