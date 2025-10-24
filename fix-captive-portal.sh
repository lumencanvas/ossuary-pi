#!/bin/bash

# Fix captive portal detection issues
# Ensures devices properly detect and show the portal

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "==========================================="
echo "    Captive Portal Fix Script"
echo "==========================================="
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

echo "Checking captive portal configuration..."

# 1. Ensure WiFi Connect is using port 80 (not 443)
echo -n "Checking port configuration... "
if grep -q "portal-listening-port 80" /etc/systemd/system/wifi-connect.service; then
    echo -e "${GREEN}✓${NC} Port 80 configured"
else
    echo -e "${YELLOW}Fixing port configuration${NC}"
    sed -i 's/--portal-listening-port [0-9]*/--portal-listening-port 80/g' /etc/systemd/system/wifi-connect.service
    systemctl daemon-reload
fi

# 2. Add captive portal detection endpoints
echo "Creating captive portal detection endpoints..."

# Create a simple detection HTML file
cat > /opt/ossuary/custom-ui/generate_204 << 'EOF'
HTTP/1.1 204 No Content
Content-Length: 0
Connection: close
EOF

cat > /opt/ossuary/custom-ui/hotspot-detect.html << 'EOF'
<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>
EOF

cat > /opt/ossuary/custom-ui/success.txt << 'EOF'
success
EOF

# 3. Add DNS hijacking for captive portal detection (when in AP mode)
echo "Configuring DNS for captive portal detection..."

# Create dnsmasq config for AP mode
cat > /tmp/captive-portal-dns.conf << 'EOF'
# Captive portal detection domains
# Apple
address=/captive.apple.com/192.168.4.1
address=/www.apple.com/192.168.4.1

# Android
address=/connectivitycheck.gstatic.com/192.168.4.1
address=/connectivitycheck.android.com/192.168.4.1
address=/clients3.google.com/192.168.4.1

# Windows
address=/www.msftconnecttest.com/192.168.4.1
address=/www.msftncsi.com/192.168.4.1

# General
address=/detectportal.firefox.com/192.168.4.1
address=/www.gstatic.com/192.168.4.1
address=/www.google.com/192.168.4.1

# Catch all for common domains
address=/#/192.168.4.1
EOF

echo -e "${YELLOW}Note: DNS hijacking config created at /tmp/captive-portal-dns.conf${NC}"
echo "This would need to be integrated with WiFi Connect's dnsmasq if issues persist"

# 4. Update custom UI to handle detection endpoints
echo "Updating custom UI for better detection..."

# Check if index.html has detection handling
if ! grep -q "generate_204" /opt/ossuary/custom-ui/index.html 2>/dev/null; then
    echo "Adding detection endpoint handling..."

    # Add JavaScript to handle detection
    cat >> /opt/ossuary/custom-ui/index.html << 'EOF'
<script>
// Handle captive portal detection
if (window.location.pathname === '/generate_204' ||
    window.location.pathname === '/hotspot-detect.html' ||
    window.location.pathname === '/success.txt') {
    // These are detection endpoints - redirect to main page
    window.location.href = '/';
}
</script>
EOF
fi

# 5. Disable HTTPS redirect if any
echo "Ensuring no HTTPS redirects..."
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo -e "${YELLOW}Nginx detected - ensuring it doesn't interfere${NC}"
    systemctl stop nginx
    systemctl disable nginx
fi

if systemctl is-active --quiet apache2 2>/dev/null; then
    echo -e "${YELLOW}Apache detected - ensuring it doesn't interfere${NC}"
    systemctl stop apache2
    systemctl disable apache2
fi

# 6. Restart WiFi Connect
echo "Restarting WiFi Connect service..."
systemctl restart wifi-connect

sleep 3

# 7. Test AP mode
echo ""
echo "Testing configuration..."

if systemctl is-active --quiet wifi-connect; then
    echo -e "${GREEN}✓${NC} WiFi Connect is running"

    # Check if in AP mode
    if ps aux | grep -q "[w]ifi-connect.*portal"; then
        echo -e "${GREEN}✓${NC} AP mode is active"
        echo ""
        echo "Captive portal should be working now!"
        echo "Look for 'Ossuary-Setup' network"
    else
        echo "Not in AP mode. To test AP mode:"
        echo "  1. Disconnect from WiFi: sudo nmcli device disconnect wlan0"
        echo "  2. Wait 60 seconds for AP mode to start"
        echo "  3. Or force it: sudo systemctl restart wifi-connect"
    fi
else
    echo -e "${RED}✗${NC} WiFi Connect failed to start"
    echo "Check logs: journalctl -u wifi-connect -n 50"
fi

echo ""
echo "==========================================="
echo "Captive Portal Tips:"
echo "==========================================="
echo ""
echo "For best captive portal detection:"
echo "  • Use HTTP on port 80 (not HTTPS)"
echo "  • Ensure no other services use port 80"
echo "  • Portal should auto-open on device connection"
echo ""
echo "If portal doesn't auto-open:"
echo "  • iOS/Mac: Should detect automatically"
echo "  • Android: Notification should appear"
echo "  • Windows: Open browser to any HTTP site"
echo "  • Manual: Browse to http://192.168.4.1"
echo ""
echo "Common issues:"
echo "  • VPN active on device (disable it)"
echo "  • Private DNS enabled (disable in WiFi settings)"
echo "  • Browser using HTTPS-only mode (disable temporarily)"
echo ""
echo "==========================================="

exit 0