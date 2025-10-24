#!/bin/bash

# Ossuary Pi - System Status Check
# Shows the status of all Ossuary services

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "==========================================="
echo "    Ossuary Pi - System Status"
echo "==========================================="
echo ""

# Check if running as root for some commands
if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Note: Run with sudo for full diagnostics${NC}"
   echo ""
fi

echo "Service Status:"
echo "---------------"

# Check WiFi Connect
echo -n "WiFi Connect (Captive Portal): "
if systemctl is-active --quiet wifi-connect; then
    echo -e "${GREEN}✓ Running${NC}"

    # Check if in AP mode
    if ps aux | grep -q "[w]ifi-connect.*portal"; then
        echo "  Mode: AP Mode Active (Ossuary-Setup)"
    else
        # Check if connected to WiFi
        SSID=$(iwgetid -r 2>/dev/null)
        if [ -n "$SSID" ]; then
            echo "  Mode: Connected to WiFi ($SSID)"
        else
            echo "  Mode: Waiting for WiFi"
        fi
    fi
else
    echo -e "${RED}✗ Not Running${NC}"
    echo "  Fix: sudo systemctl start wifi-connect"
fi

echo ""

# Check Web Config Server
echo -n "Web Configuration Server: "
if systemctl is-active --quiet ossuary-web; then
    echo -e "${GREEN}✓ Running${NC}"

    # Check if port 80 is listening
    if netstat -tuln 2>/dev/null | grep -q ":80 "; then
        echo "  Port 80: Listening"
        IP=$(hostname -I | awk '{print $1}')
        echo "  Access: http://$(hostname) or http://$IP"
    else
        echo "  ${YELLOW}Warning: Port 80 not detected${NC}"
    fi
else
    echo -e "${RED}✗ Not Running${NC}"
    echo "  Fix: sudo systemctl start ossuary-web"
fi

echo ""

# Check Startup Service
echo -n "Startup Command Service: "
if systemctl is-enabled --quiet ossuary-startup; then
    echo -e "${GREEN}✓ Enabled${NC}"

    # Check if config exists and has a command
    if [ -f /etc/ossuary/config.json ]; then
        CMD=$(grep -o '"startup_command"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/ossuary/config.json | sed 's/.*:[[:space:]]*"\(.*\)"/\1/')
        if [ -n "$CMD" ]; then
            echo "  Command: $CMD"
        else
            echo "  Command: (none configured)"
        fi
    else
        echo "  ${YELLOW}No config file${NC}"
    fi
else
    echo -e "${RED}✗ Not Enabled${NC}"
    echo "  Fix: sudo systemctl enable ossuary-startup"
fi

echo ""
echo "Network Status:"
echo "---------------"

# WiFi Interface
WIFI_IF=$(ip link | grep -E '^[0-9]+: wl' | cut -d: -f2 | tr -d ' ' | head -n1)
if [ -n "$WIFI_IF" ]; then
    echo "WiFi Interface: $WIFI_IF"

    # Check if connected
    SSID=$(iwgetid -r 2>/dev/null)
    if [ -n "$SSID" ]; then
        echo -e "Connected to: ${GREEN}$SSID${NC}"
        IP=$(hostname -I | awk '{print $1}')
        echo "IP Address: $IP"
    else
        echo -e "WiFi Status: ${YELLOW}Not connected${NC}"

        # Check if AP mode is active
        if iw dev "$WIFI_IF" info 2>/dev/null | grep -q "type AP"; then
            echo -e "AP Mode: ${GREEN}Active${NC} (Ossuary-Setup)"
        else
            echo "AP Mode: Inactive"
        fi
    fi
else
    echo -e "${RED}No WiFi interface detected${NC}"
fi

echo ""
echo "File Locations:"
echo "---------------"
echo "Installation: /opt/ossuary"
echo "Configuration: /etc/ossuary/config.json"
echo "Custom UI: /opt/ossuary/custom-ui"
echo "Logs: journalctl -u wifi-connect -u ossuary-web -u ossuary-startup"

echo ""
echo "Quick Commands:"
echo "---------------"
echo "View WiFi Connect logs:    journalctl -u wifi-connect -f"
echo "View web server logs:      journalctl -u ossuary-web -f"
echo "Restart all services:      sudo systemctl restart wifi-connect ossuary-web"
echo "Force AP mode:             sudo systemctl stop NetworkManager && sudo systemctl restart wifi-connect"

echo ""
echo "==========================================="

# If running as root, check for issues
if [[ $EUID -eq 0 ]]; then
    ISSUES=0

    if ! systemctl is-active --quiet wifi-connect; then
        ISSUES=$((ISSUES + 1))
    fi

    if ! systemctl is-active --quiet ossuary-web; then
        ISSUES=$((ISSUES + 1))
    fi

    if [ $ISSUES -gt 0 ]; then
        echo -e "${YELLOW}⚠ $ISSUES service(s) need attention${NC}"
    else
        echo -e "${GREEN}✓ All services operational${NC}"
    fi
else
    echo "Run with sudo for full diagnostics"
fi

echo "==========================================="